import Foundation

struct OpenAIResponsesProvider: LLMProvider {
    let apiKey: String
    let model: String
    var effort = "default"
    var tokenLimit = 4096
    var fastMode = false

    func requestBody(messages: [LLMMessage], system: String) -> [String: Any] {
        var body: [String: Any] = ["model": model, "instructions": system, "stream": true, "store": false,
                                   "max_output_tokens": tokenLimit,
                                   "input": messages.map { ["role": $0.role, "content": $0.content] }]
        if effort != "default" { body["reasoning"] = ["effort": effort] }
        if fastMode { body["service_tier"] = "priority" }
        return body
    }
    static func textDelta(_ data: Data) throws -> String? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let type = object["type"] as? String else { return nil }
        if type == "error" || type == "response.failed" || type == "response.incomplete" {
            let response = object["response"] as? [String: Any] ?? [:]
            let error = response["error"] as? [String: Any] ?? object["error"] as? [String: Any] ?? [:]
            throw KuraError.message(error["message"] as? String ?? object["message"] as? String ?? "OpenAI did not complete the answer. Try lower reasoning effort or a different model.")
        }
        return type == "response.output_text.delta" ? object["delta"] as? String : nil
    }
    /// The terminal `response.completed` event carries the billable totals. Cached tokens
    /// are a subset of input_tokens, so normalize them out of the full-rate count.
    static func usage(_ data: Data) -> LLMUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "response.completed",
              let usage = (object["response"] as? [String: Any])?["usage"] as? [String: Any],
              let input = usage["input_tokens"] as? Int,
              let output = usage["output_tokens"] as? Int else { return nil }
        let cached = (usage["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int
        return LLMUsage(inputTokens: max(0, input - (cached ?? 0)), outputTokens: output, cachedInputTokens: cached)
    }
    func stream(messages: [LLMMessage], system: String) -> AsyncThrowingStream<String, Error> {
        stream(messages: messages, system: system, onUsage: nil)
    }
    func stream(messages: [LLMMessage], system: String, onUsage: (@Sendable (LLMUsage) -> Void)?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw LLMError.missingAPIKey("OpenAI") }
                    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 20 // Idle-stall abort; the timer resets as deltas arrive.
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(messages: messages, system: system))
                    var usage: LLMUsage?
                    for try await payload in SSEStream.payloads(for: request) {
                        if let parsed = Self.usage(payload) { usage = parsed }
                        if let delta = try Self.textDelta(payload) { continuation.yield(delta) }
                    }
                    if let usage { onUsage?(usage) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
