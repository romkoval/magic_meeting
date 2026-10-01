import Foundation

/// Address and pilot token of our proxy, taken from Info.plist (filled from Config/*.xcconfig).
/// The Groq key is never in the app.
struct ProxyConfiguration: Sendable {
    let baseURL: URL
    let clientToken: String?

    static func fromBundle(_ bundle: Bundle = .main) -> ProxyConfiguration? {
        guard let raw = bundle.object(forInfoDictionaryKey: "ProxyBaseURL") as? String,
              let url = URL(string: raw), url.host() != nil, url.host() != "proxy.example.com"
        else { return nil }
        let token = (bundle.object(forInfoDictionaryKey: "ProxyClientToken") as? String)?
            .trimmingCharacters(in: .whitespaces)
        return ProxyConfiguration(baseURL: url, clientToken: token?.isEmpty == false ? token : nil)
    }
}

enum ProxyError: LocalizedError {
    case notConfigured
    case offline
    case server(status: Int, message: String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            String(localized: "The server address is not configured.")
        case .offline:
            String(localized: "No connection to the server.")
        case .server(let status, _):
            switch status {
            case 401, 403: String(localized: "The server denied access.")
            case 413: String(localized: "The audio file is too large.")
            case 429, 503: String(localized: "The service is busy. Try again later.")
            case 504: String(localized: "The service did not respond in time.")
            default: String(localized: "Server error (\(status)).")
            }
        case .invalidResponse:
            String(localized: "Unexpected response from the server.")
        }
    }

    var isRetryable: Bool {
        if case .server(let status, _) = self {
            return [429, 500, 502, 503, 504].contains(status)
        }
        return false
    }

    static var offlineCodes: Set<URLError.Code> {
        [
            .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
            .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut,
            .internationalRoamingOff, .callIsActive,
        ]
    }
}

struct TranscriptionResponse: Decodable, Sendable {
    let text: String
    let language: String?
    let duration: Double?
    let segments: [TranscriptTiming]?
}

enum LLMOperation: String, Sendable {
    case summarize
    case `protocol`
    case editTranscript = "edit_transcript"
    case editText = "edit_text"
    case highlight
    case pickTemplate = "pick_template"
    case draftTemplate = "draft_template"
}

struct LLMTemplateRef: Encodable, Sendable {
    let id: String
    let name: String
}

/// Input for `/v1/llm`; each operation uses its own subset (see proxy/README.md).
struct LLMInput: Encodable, Sendable {
    var transcript: String?
    var summary: String?
    var text: String?
    var command: String?
    var highlights: [String]?
    var template: String?
    var date: String?
    var duration: String?
    var glossary: [String]?
    var templates: [LLMTemplateRef]?
    var description: String?
    var language: String?
    var uiLanguage: String?
}

struct SummaryResult: Decodable, Sendable {
    let title: String
    let summary: String
}

struct TextResult: Decodable, Sendable {
    let text: String
}

private struct LLMRequestBody: Encodable {
    let op: String
    let input: LLMInput
}

private struct LLMEnvelope<Result: Decodable & Sendable>: Decodable, Sendable {
    let result: Result
}

private struct ErrorBody: Decodable {
    let error: String
}

/// Talks to the proxy. Transient failures are retried here; anything left is
/// reported to the caller, which keeps the audio and lets the user retry.
struct ProxyClient: Sendable {
    let configuration: ProxyConfiguration
    let deviceID: String
    var session: URLSession = .shared
    var maxAttempts = 3

    func transcribe(fileURL: URL, glossary: [String], language: String?) async throws -> TranscriptionResponse {
        let audio = try Data(contentsOf: fileURL)
        var form = MultipartForm()
        form.addFile(name: "file", fileName: "audio.m4a", mimeType: "audio/mp4", data: audio)
        if !glossary.isEmpty {
            form.addField(name: "glossary", value: glossary.joined(separator: "\n"))
        }
        if let language, !language.isEmpty {
            form.addField(name: "language", value: language)
        }
        var request = makeRequest(path: "v1/transcribe", timeout: 300)
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        return try await send(request, body: form.finalized())
    }

    func llm<Result: Decodable & Sendable>(_ operation: LLMOperation, _ input: LLMInput, as _: Result.Type = Result.self) async throws -> Result {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let body = try encoder.encode(LLMRequestBody(op: operation.rawValue, input: input))
        var request = makeRequest(path: "v1/llm", timeout: 120)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let envelope: LLMEnvelope<Result> = try await send(request, body: body)
        return envelope.result
    }

    private func makeRequest(path: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: configuration.baseURL.appending(path: path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(deviceID, forHTTPHeaderField: "X-Device-ID")
        if let token = configuration.clientToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send<T: Decodable & Sendable>(_ request: URLRequest, body: Data) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, response) = try await session.upload(for: request, from: body)
                guard let http = response as? HTTPURLResponse else { throw ProxyError.invalidResponse }
                if (200..<300).contains(http.statusCode) {
                    guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
                        throw ProxyError.invalidResponse
                    }
                    return decoded
                }
                let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
                let error = ProxyError.server(status: http.statusCode, message: message)
                guard error.isRetryable, attempt < maxAttempts else { throw error }
                try await Task.sleep(for: .seconds(retryDelay(attempt: attempt, response: http)))
            } catch let error as URLError {
                guard ProxyError.offlineCodes.contains(error.code) else { throw error }
                guard attempt < maxAttempts else { throw ProxyError.offline }
                try await Task.sleep(for: .seconds(retryDelay(attempt: attempt, response: nil)))
            }
        }
    }

    private func retryDelay(attempt: Int, response: HTTPURLResponse?) -> Double {
        if let header = response?.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(header) {
            return min(seconds, 30)
        }
        return pow(2, Double(attempt)) // 2s, 4s
    }
}

struct MultipartForm {
    let boundary = "Boundary-\(UUID().uuidString)"
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(name: String, value: String) {
        body.append(string: "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.append(string: value)
        body.append(string: "\r\n")
    }

    mutating func addFile(name: String, fileName: String, mimeType: String, data: Data) {
        body.append(string: "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\nContent-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.append(string: "\r\n")
    }

    func finalized() -> Data {
        var data = body
        data.append(string: "--\(boundary)--\r\n")
        return data
    }
}

private extension Data {
    mutating func append(string: String) {
        append(Data(string.utf8))
    }
}
