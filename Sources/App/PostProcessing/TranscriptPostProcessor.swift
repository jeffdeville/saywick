import Foundation
import FoundationModels
import VoiceKeyboardCore

enum PostProcessingError: LocalizedError {
    case foundationModelUnavailable(SystemLanguageModel.Availability)
    case inputTooLarge
    case wordingChanged

    var errorDescription: String? {
        switch self {
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
        case .foundationModels, .foundationModelsStructured:
            return try await processWithFoundationModels(
                text,
                customInstructions: customInstructions,
                preferredWords: preferredWords,
                structured: processor == .foundationModelsStructured
            )
        }
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
