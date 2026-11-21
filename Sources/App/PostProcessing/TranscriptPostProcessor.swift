import Foundation
import FoundationModels
import Security
import VoiceKeyboardCore

enum PostProcessingError: LocalizedError {
    case foundationModelUnavailable(SystemLanguageModel.Availability)
    case inputTooLarge
    case wordingChanged
    case modelRejected
    case openAIUnavailable

    var errorDescription: String? {
        switch self {
        case .modelRejected: "Check the template model ID and your account’s access."
        case .openAIUnavailable:
            "OpenAI cleanup is unavailable. Check the API key and network connection. Original text is preserved."
        case .inputTooLarge:
            "Cleanup could not fit this section or preference. Try a shorter formatting preference. Original text is preserved."
        case .wordingChanged:
            "Cleanup changed or omitted words, so its output was rejected. Original text is preserved."
        case .foundationModelUnavailable(let availability):
            "Apple’s on-device language model is unavailable: \(String(describing: availability))."
        }
    }
}

@Generable
private struct CleanedTranscript {
    @Guide(description: "The corrected target: join fragments split by thinking pauses into grammatical sentences. Preserve all words in order. No context or labels.")
    var text: String
}

enum TranscriptPostProcessor {
    static let standardModel = "gpt-6-luna"
    static func process(
        _ text: String,
        using processor: PostProcessorID,
        customInstructions: String,
        preferredWords: [String] = []
    ) async throws -> String {
        guard !text.isEmpty else { return "" }

        switch processor {
        case .none:
            return text
        case .rules:
            return RuleBasedCleaner.clean(text)
        case .openAILuna:
            return try await processWithOpenAI(text, customInstructions: customInstructions, preferredWords: preferredWords)
        case .foundationModels, .foundationModelsStructured:
            return try await processWithFoundationModels(
                text,
                customInstructions: customInstructions,
                preferredWords: preferredWords,
                structured: processor == .foundationModelsStructured
            )
        }
    }

    private static func processWithOpenAI(_ text: String, customInstructions: String, preferredWords: [String]) async throws -> String {
        guard let key = OpenAIKeyStore.read(), !key.isEmpty else { throw PostProcessingError.openAIUnavailable }
        let preference = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard preference.utf8.count <= 500 else { throw PostProcessingError.inputTooLarge }
        var output: [String] = []
        for chunk in TranscriptCleanup.chunks(text) {
            try Task.checkCancellation()
            let context = [chunk.before, chunk.text, chunk.after].joined(separator: " ")
            let words = preferredWords.filter { context.localizedCaseInsensitiveContains($0) }
            guard chunk.text.utf8.count <= TranscriptCleanup.targetByteLimit,
                  words.joined(separator: ", ").utf8.count <= 500 else { throw PostProcessingError.inputTooLarge }
            let content = try await openAICompletion(
                key: key,
                instructions: TranscriptCleanup.instructions(structured: false),
                input: TranscriptCleanup.prompt(chunk, preference: preference, preferredWords: words)
            )
            let cleaned = TranscriptOutputSanitizer.clean(content)
            guard TranscriptCleanup.preservesWords(source: chunk.text, candidate: cleaned),
                  !TranscriptCleanup.hasListMarkup(cleaned) else { throw PostProcessingError.wordingChanged }
            output.append(cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        }
        return RuleBasedCleaner.clean(output.joined(separator: " "))
    }

    /// A named prompt operates on the entire finished dictation and owns its output format.
    static func applyTemplate(
        _ prompt: String, to transcript: String, modelID: String = standardModel,
        readKey: () -> String? = OpenAIKeyStore.read,
        send: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    ) async throws -> String {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        guard let key = readKey(), !key.isEmpty else { throw PostProcessingError.openAIUnavailable }
        return try await openAICompletion(key: key, instructions: prompt, input: transcript, modelID: modelID, send: send)
    }

    private static func openAICompletion(
        key: String, instructions: String, input: String, modelID: String = standardModel,
        send: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    ) async throws -> String {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [
            "model": modelID,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": input]
            ]
        ]
        if modelID == standardModel { payload["reasoning_effort"] = "none" }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await send(request)
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, [400, 403, 404].contains(http.statusCode),
           modelID != standardModel { throw PostProcessingError.modelRejected }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]], let choice = choices.first,
              choice["finish_reason"] as? String == "stop",
              let message = choice["message"] as? [String: Any], message["refusal"] as? String == nil,
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PostProcessingError.openAIUnavailable
        }
        return content
    }

    private static func processWithFoundationModels(
        _ text: String,
        customInstructions: String,
        preferredWords: [String],
        structured: Bool
    ) async throws -> String {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw PostProcessingError.foundationModelUnavailable(model.availability)
        }
        let preference = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard preference.utf8.count <= 500 else { throw PostProcessingError.inputTooLarge }
        var output: [String] = []
        for chunk in TranscriptCleanup.chunks(text) {
            try Task.checkCancellation()
            // Only relevant vocabulary enters each request. A new session keeps
            // earlier requests/responses from exhausting the context window.
            let context = [chunk.before, chunk.text, chunk.after].joined(separator: " ")
            let relevantWords = preferredWords.filter { context.localizedCaseInsensitiveContains($0) }
            guard chunk.text.utf8.count <= TranscriptCleanup.targetByteLimit,
                  relevantWords.joined(separator: ", ").utf8.count <= 500 else {
                throw PostProcessingError.inputTooLarge
            }
            let session = LanguageModelSession(instructions: TranscriptCleanup.instructions(structured: structured))
            let response = try await session.respond(
                to: TranscriptCleanup.prompt(chunk, preference: preference, preferredWords: relevantWords),
                generating: CleanedTranscript.self,
                options: GenerationOptions(temperature: 0))
            try Task.checkCancellation()
            let cleaned = TranscriptOutputSanitizer.clean(response.content.text)
            guard TranscriptCleanup.preservesWords(source: chunk.text, candidate: cleaned),
                  structured || !TranscriptCleanup.hasListMarkup(cleaned) else {
                throw PostProcessingError.wordingChanged
            }
            output.append(structured ? cleaned : cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        }
        let result = output.joined(separator: " ")
        return structured ? result : RuleBasedCleaner.clean(result)
    }
}

/// The credential stays in the containing app's Keychain, outside shared keyboard storage.
enum OpenAIKeyStore {
    private static let service = "Saywick.OpenAI"
    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "api-key", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "api-key"]
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw PostProcessingError.openAIUnavailable }
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw PostProcessingError.openAIUnavailable }
        } else if status != errSecSuccess { throw PostProcessingError.openAIUnavailable }
    }
}
