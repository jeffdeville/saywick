import Foundation

/// The standalone Azure Speech API. Kept independent of microphone/UI code.
public enum MAITranscriptionAPI {
    public static func endpoint(_ source: String) throws -> URL {
        guard var parts = URLComponents(string: source.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", let host = parts.host,
              host.hasSuffix(".cognitiveservices.azure.com"),
              parts.user == nil, parts.password == nil,
              parts.port == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else {
            throw APIError.invalidEndpoint
        }
        parts.path = "/speechtotext/transcriptions:transcribe"
        parts.queryItems = [URLQueryItem(name: "api-version", value: "2025-10-15")]
        guard let url = parts.url else { throw APIError.invalidEndpoint }
        return url
    }

    public static func multipart(audio: Data, boundary: String) -> Data {
        let definition = #"{"enhancedMode":{"enabled":true,"model":"MAI-Transcribe-2","modelOptions":{"transcribeStyle":"clean"}},"diarization":{"enabled":false}}"#
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"definition\"\r\nContent-Type: application/json\r\n\r\n\(definition)\r\n".utf8)
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    public static func transcript(from data: Data) throws -> String {
        struct Response: Decodable {
            struct Phrase: Decodable { let text: String }
            let combinedPhrases: [Phrase]
        }
        // Do not concatenate `phrases` as well: they repeat the combined text.
        return try JSONDecoder().decode(Response.self, from: data).combinedPhrases
            .map(\.text).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public enum APIError: LocalizedError {
        case invalidEndpoint
        public var errorDescription: String? {
            "Enter the HTTPS resource endpoint from Azure Speech → Keys and Endpoint (https://your-resource.cognitiveservices.azure.com/)."
        }
    }
}
