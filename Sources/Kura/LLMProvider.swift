// LLM providers — streaming chat over Anthropic, OpenAI-compatible, and local Ollama APIs.
import Foundation

enum LLMError: LocalizedError {
    case missingAPIKey(String)
    case http(Int, String)
    case localServerUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let name): return "Missing API key for \(name). Open settings (⌃⌥,) to add it."
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .localServerUnavailable(let address):
            return "Can't reach Ollama at \(address). Start Ollama, then try again."
        }
    }
}

struct LLMMessage: Sendable {
    let role: String // "user" or "assistant"
    let content: String
}

protocol LLMProvider: Sendable {
    func stream(messages: [LLMMessage], system: String) -> AsyncThrowingStream<String, Error>
}

/// Security may wait for a macOS access prompt. Never do that on the UI thread.
struct KeychainBackedProvider: LLMProvider {
    let account: String
    let factory: @Sendable (String) -> any LLMProvider
    func stream(messages: [LLMMessage], system: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let key = await Task.detached { Keychain.get(account: account, allowInteraction: true) ?? "" }.value
                    try Task.checkCancellation()
                    for try await text in factory(key).stream(messages: messages, system: system) {
                        try Task.checkCancellation(); continuation.yield(text)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Shared SSE helper

struct SSEStream {
    /// Yields raw `data:` payloads (decoded JSON objects) from an SSE response.
    static func payloads(for request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.http(-1, "no HTTP response")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw LLMError.http(http.statusCode, body)
                    }
                    for try await line in bytes.lines {
                        guard !Task.isCancelled else { break }
                        guard line.hasPrefix("data:") else { continue }
                        var payload = line.dropFirst(5)
                        if payload.hasPrefix(" ") { payload = payload.dropFirst() }
                        if payload == "[DONE]" { break }
                        if let data = String(payload).data(using: .utf8) {
                            continuation.yield(data)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Yields one JSON object per line, as used by Ollama's streaming API.
struct JSONLineStream {
    static func payloads(for request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.http(-1, "no HTTP response")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw LLMError.http(http.statusCode, body)
                    }
                    for try await line in bytes.lines {
                        guard !Task.isCancelled else { break }
                        guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Anthropic

struct AnthropicProvider: LLMProvider {
    let apiKey: String
    let model: String
    var effort = "default"
    var adaptiveThinking = false
    var tokenLimit = 4096

    func requestBody(messages: [LLMMessage], system: String) -> [String: Any] {
        var body: [String: Any] = ["model": model, "max_tokens": tokenLimit, "stream": true, "system": system,
                                   "messages": messages.map { ["role": $0.role, "content": $0.content] }]
        if effort != "default" {
            body["output_config"] = ["effort": effort]
            if adaptiveThinking { body["thinking"] = ["type": "adaptive"] }
        }
        return body
    }

    func stream(messages: [LLMMessage], system: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw LLMError.missingAPIKey("Anthropic") }
                    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                    request.httpMethod = "POST"
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.setValue("application/json", forHTTPHeaderField: "content-type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(messages: messages, system: system))
                    for try await payload in SSEStream.payloads(for: request) {
                        guard let obj = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { continue }
                        if obj["type"] as? String == "error" { throw LLMError.http(200, String(data: payload, encoding: .utf8) ?? "Streaming error") }
                        if obj["type"] as? String == "message_delta",
                           (obj["delta"] as? [String: Any])?["stop_reason"] as? String == "max_tokens" {
                            throw KuraError.message("Claude reached the output/reasoning budget. Lower effort or increase the token budget in Settings.")
                        }
                        guard obj["type"] as? String == "content_block_delta",
                              let delta = obj["delta"] as? [String: Any],
                              delta["type"] as? String == "text_delta",
                              let text = delta["text"] as? String else { continue }
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - OpenAI-compatible

struct OpenAICompatibleProvider: LLMProvider {
    let apiKey: String
    let baseURL: String
    let model: String
    var effort: String = "minimal"

    func stream(messages: [LLMMessage], system: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw LLMError.missingAPIKey("OpenAI-compatible") }
                    let base = baseURL.isEmpty ? "https://api.openai.com/v1" : baseURL
                    guard let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else {
                        throw LLMError.http(-1, "invalid base URL")
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "content-type")
                    var body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "messages": [["role": "system", "content": system]]
                            + messages.map { ["role": $0.role, "content": $0.content] },
                    ]
                    // Latency tuning: GPT-5/o-series are reasoning models — reasoning inflates
                    // time-to-first-token 5-30x, so force minimal effort and cap output length.
                    if model.hasPrefix("gpt-5") || model.hasPrefix("gpt-6") || model.hasPrefix("o1") || model.hasPrefix("o3") || model.hasPrefix("o4") {
                        body["reasoning_effort"] = effort
                        body["max_completion_tokens"] = 4096
                    }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    for try await payload in SSEStream.payloads(for: request) {
                        guard let obj = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { continue }
                        if obj["error"] != nil { throw LLMError.http(200, String(data: payload, encoding: .utf8) ?? "Streaming error") }
                        guard
                              let choices = obj["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let text = delta["content"] as? String else { continue }
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Ollama (local)

/// Streams from a locally running Ollama server. Ollama's native API is line-delimited JSON,
/// rather than the SSE format used by OpenAI-compatible providers.
struct OllamaProvider: LLMProvider {
    let baseURL: String
    let model: String

    private var normalizedBaseURL: String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "http://127.0.0.1:11434" : trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func stream(messages: [LLMMessage], system: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: normalizedBaseURL + "/api/chat") else {
                        throw LLMError.http(-1, "invalid Ollama server URL")
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 120
                    request.setValue("application/json", forHTTPHeaderField: "content-type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": model,
                        "stream": true,
                        "keep_alive": "10m",
                        "messages": [["role": "system", "content": system]]
                            + messages.map { ["role": $0.role, "content": $0.content] },
                    ])
                    for try await payload in JSONLineStream.payloads(for: request) {
                        guard let obj = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { continue }
                        if let error = obj["error"] as? String { throw LLMError.http(200, error) }
                        guard
                              let message = obj["message"] as? [String: Any],
                              let text = message["content"] as? String,
                              !text.isEmpty else { continue }
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    if let urlError = error as? URLError,
                       [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost].contains(urlError.code) {
                        continuation.finish(throwing: LLMError.localServerUnavailable(normalizedBaseURL))
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func installedModels(baseURL: String) async throws -> [String] {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (trimmed.isEmpty ? "http://127.0.0.1:11434" : trimmed).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/api/tags") else {
            throw LLMError.http(-1, "invalid Ollama server URL")
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                throw LLMError.http(-1, "no HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let models = object?["models"] as? [[String: Any]] ?? []
            // Preserve Ollama's order so the first installed model is the deterministic
            // default when no saved selection is available.
            return models.compactMap { $0["name"] as? String }
        } catch let error as LLMError {
            throw error
        } catch let error as URLError where [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost].contains(error.code) {
            throw LLMError.localServerUnavailable(base)
        }
    }
}
