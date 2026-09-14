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

/// Token counts for one billable call. `inputTokens` is normalized across providers to
/// EXCLUDE `cachedInputTokens`: OpenAI reports cached tokens inside input_tokens while
/// Anthropic reports them separately — parsers align both to this convention so pricing
/// math is uniform. Audio splits are only set by the realtime engine.
struct LLMUsage: Equatable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
    var cachedInputTokens: Int?
    var audioInputTokens: Int?
    var audioOutputTokens: Int?
    init(inputTokens: Int, outputTokens: Int, cachedInputTokens: Int? = nil, audioInputTokens: Int? = nil, audioOutputTokens: Int? = nil) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.audioInputTokens = audioInputTokens; self.audioOutputTokens = audioOutputTokens
    }
}

/// The usage callback fires from the provider's network task while the consumer reads
/// the result after the stream ends on the main actor; the lock keeps that handoff safe.
final class LLMUsageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: LLMUsage?
    var usage: LLMUsage? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

protocol LLMProvider: Sendable {
    func stream(messages: [LLMMessage], system: String) -> AsyncThrowingStream<String, Error>
    /// Usage-aware variant. `onUsage` fires at most once per call, after the final text
    /// delta and before the stream finishes. Providers that cannot report usage use the
    /// default implementation, which simply never calls it.
    func stream(messages: [LLMMessage], system: String, onUsage: (@Sendable (LLMUsage) -> Void)?) -> AsyncThrowingStream<String, Error>
}

extension LLMProvider {
    func stream(messages: [LLMMessage], system: String, onUsage: (@Sendable (LLMUsage) -> Void)?) -> AsyncThrowingStream<String, Error> {
        stream(messages: messages, system: system)
    }
}

enum StreamTiming {
    /// Lets the first-delta race and the steady-state drain share one iterator;
    /// only one task calls next() at a time.
    private final class IteratorBox: @unchecked Sendable {
        var iterator: AsyncThrowingStream<String, Error>.Iterator
        init(_ stream: AsyncThrowingStream<String, Error>) { iterator = stream.makeAsyncIterator() }
    }

    /// Fails if the first delta takes longer than `seconds`; later deltas pass through unthrottled.
    /// URLSession's per-request idle timeout still covers stalls after the first delta.
    static func firstDelta(_ stream: AsyncThrowingStream<String, Error>, within seconds: Double) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let box = IteratorBox(stream)
                    let first: String? = try await withThrowingTaskGroup(of: String?.self) { group in
                        group.addTask { try await box.iterator.next() }
                        group.addTask {
                            try await Task.sleep(for: .seconds(seconds))
                            try Task.checkCancellation()
                            throw KuraError.message("No response within \(Int(seconds)) seconds.")
                        }
                        let value = try await group.next()!
                        group.cancelAll()
                        return value
                    }
                    if let first {
                        continuation.yield(first)
                        while let delta = try await box.iterator.next() {
                            try Task.checkCancellation(); continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Security may wait for a macOS access prompt. Never do that on the UI thread.
struct KeychainBackedProvider: LLMProvider {
    let account: String
    let factory: @Sendable (String) -> any LLMProvider
    func stream(messages: [LLMMessage], system: String) -> AsyncThrowingStream<String, Error> {
        stream(messages: messages, system: system, onUsage: nil)
    }
    func stream(messages: [LLMMessage], system: String, onUsage: (@Sendable (LLMUsage) -> Void)?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let key = await Task.detached { Keychain.get(account: account, allowInteraction: true) ?? "" }.value
                    try Task.checkCancellation()
                    for try await text in factory(key).stream(messages: messages, system: system, onUsage: onUsage) {
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

    /// Usage arrives split across two events: input tokens (and cache reads) on
    /// `message_start`, cumulative output tokens on each `message_delta`. Each call
    /// returns that event's partial; the stream merges them and reports once at the end.
    static func usage(from payload: Data) -> LLMUsage? {
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        switch type {
        case "message_start":
            guard let usage = (obj["message"] as? [String: Any])?["usage"] as? [String: Any],
                  let input = usage["input_tokens"] as? Int else { return nil }
            // Anthropic bills cache reads separately from input_tokens — no normalization needed.
            return LLMUsage(inputTokens: input, outputTokens: 0, cachedInputTokens: usage["cache_read_input_tokens"] as? Int)
        case "message_delta":
            guard let usage = obj["usage"] as? [String: Any], let output = usage["output_tokens"] as? Int else { return nil }
            return LLMUsage(inputTokens: 0, outputTokens: output)
        default:
            return nil
        }
    }

    func stream(messages: [LLMMessage], system: String) -> AsyncThrowingStream<String, Error> {
        stream(messages: messages, system: system, onUsage: nil)
    }

    func stream(messages: [LLMMessage], system: String, onUsage: (@Sendable (LLMUsage) -> Void)?) -> AsyncThrowingStream<String, Error> {
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
                    var usage: LLMUsage?
                    for try await payload in SSEStream.payloads(for: request) {
                        guard let obj = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { continue }
                        if obj["type"] as? String == "error" { throw LLMError.http(200, String(data: payload, encoding: .utf8) ?? "Streaming error") }
                        if obj["type"] as? String == "message_delta",
                           (obj["delta"] as? [String: Any])?["stop_reason"] as? String == "max_tokens" {
                            throw KuraError.message("Claude reached the output/reasoning budget. Lower effort or increase the token budget in Settings.")
                        }
                        if let partial = Self.usage(from: payload) {
                            var merged = usage ?? LLMUsage(inputTokens: 0, outputTokens: 0)
                            merged.inputTokens += partial.inputTokens
                            merged.outputTokens = max(merged.outputTokens, partial.outputTokens)
                            if let cached = partial.cachedInputTokens { merged.cachedInputTokens = cached }
                            usage = merged
                        }
                        guard obj["type"] as? String == "content_block_delta",
                              let delta = obj["delta"] as? [String: Any],
                              delta["type"] as? String == "text_delta",
                              let text = delta["text"] as? String else { continue }
                        continuation.yield(text)
                    }
                    if let usage { onUsage?(usage) }
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

    /// The final SSE chunk(s) carry a `usage` object when the request asks for it;
    /// cached tokens are a subset of prompt_tokens, so normalize them out.
    static func usage(from payload: Data) -> LLMUsage? {
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let usage = obj["usage"] as? [String: Any],
              let prompt = usage["prompt_tokens"] as? Int,
              let completion = usage["completion_tokens"] as? Int else { return nil }
        let cached = (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int
        return LLMUsage(inputTokens: max(0, prompt - (cached ?? 0)), outputTokens: completion, cachedInputTokens: cached)
    }

    func stream(messages: [LLMMessage], system: String) -> AsyncThrowingStream<String, Error> {
        stream(messages: messages, system: system, onUsage: nil)
    }

    func stream(messages: [LLMMessage], system: String, onUsage: (@Sendable (LLMUsage) -> Void)?) -> AsyncThrowingStream<String, Error> {
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
                        "stream_options": ["include_usage": true],
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
                    var usage: LLMUsage?
                    for try await payload in SSEStream.payloads(for: request) {
                        guard let obj = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { continue }
                        if obj["error"] != nil { throw LLMError.http(200, String(data: payload, encoding: .utf8) ?? "Streaming error") }
                        if let parsed = Self.usage(from: payload) { usage = parsed; continue }
                        guard
                              let choices = obj["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let text = delta["content"] as? String else { continue }
                        continuation.yield(text)
                    }
                    if let usage { onUsage?(usage) }
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

    /// Ollama's final line (`done: true`) carries the eval counts. Local inference has no
    /// dollar price, but the token counts are still useful for the per-answer caption.
    static func usage(from payload: Data) -> LLMUsage? {
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              obj["done"] as? Bool == true else { return nil }
        let input = obj["prompt_eval_count"] as? Int ?? 0
        let output = obj["eval_count"] as? Int ?? 0
        guard input > 0 || output > 0 else { return nil }
        return LLMUsage(inputTokens: input, outputTokens: output)
    }

    func stream(messages: [LLMMessage], system: String) -> AsyncThrowingStream<String, Error> {
        stream(messages: messages, system: system, onUsage: nil)
    }

    func stream(messages: [LLMMessage], system: String, onUsage: (@Sendable (LLMUsage) -> Void)?) -> AsyncThrowingStream<String, Error> {
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
                    var usage: LLMUsage?
                    for try await payload in JSONLineStream.payloads(for: request) {
                        guard let obj = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { continue }
                        if let error = obj["error"] as? String { throw LLMError.http(200, error) }
                        if let parsed = Self.usage(from: payload) { usage = parsed }
                        guard
                              let message = obj["message"] as? [String: Any],
                              let text = message["content"] as? String,
                              !text.isEmpty else { continue }
                        continuation.yield(text)
                    }
                    if let usage { onUsage?(usage) }
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
