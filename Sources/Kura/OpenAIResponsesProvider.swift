import Foundation

struct OpenAIResponsesProvider: LLMProvider {
    let apiKey: String
    let model: String
    var effort = "default"
    var tokenLimit = 4096

    func requestBody(messages: [LLMMessage], system: String) -> [String: Any] {
        var body: [String: Any] = ["model": model, "instructions": system, "stream": true, "store": false,
                                   "max_output_tokens": tokenLimit,
                                   "input": messages.map { ["role": $0.role, "content": $0.content] }]
        if effort != "default" { body["reasoning"] = ["effort": effort] }
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
    func stream(messages: [LLMMessage], system: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw LLMError.missingAPIKey("OpenAI") }
                    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(messages: messages, system: system))
                    for try await payload in SSEStream.payloads(for: request) {
                        if let delta = try Self.textDelta(payload) { continuation.yield(delta) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
