import Foundation

struct AvailableModel: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var efforts: [String] = []
    var adaptiveThinking = false
}

enum ModelCatalog {
    static func parse(_ data: Data) throws -> (models: [AvailableModel], next: String?) {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else { throw KuraError.message("The provider returned an invalid model list.") }
        let models = rows.compactMap { row -> AvailableModel? in
            guard let id = row["id"] as? String else { return nil }
            let capabilities = row["capabilities"] as? [String: Any] ?? [:]
            let effort = capabilities["effort"] as? [String: Any] ?? [:]
            let levels = ["low", "medium", "high", "xhigh", "max"].filter { (effort[$0] as? [String: Any])?["supported"] as? Bool == true }
            let thinking = capabilities["thinking"] as? [String: Any] ?? [:]
            let types = thinking["types"] as? [String: Any] ?? [:]
            return AvailableModel(id: id, name: row["display_name"] as? String ?? id, efforts: levels,
                                  adaptiveThinking: (types["adaptive"] as? [String: Any])?["supported"] as? Bool == true)
        }
        let next = object["has_more"] as? Bool == true ? object["last_id"] as? String : nil
        if object["has_more"] as? Bool == true && next == nil { throw KuraError.message("Model pagination was incomplete. Please refresh again.") }
        return (models, next)
    }
    static func cached(_ provider: ProviderKind) -> [AvailableModel] {
        guard let data = UserDefaults.standard.data(forKey: "modelCatalog-\(provider.rawValue)") else { return [] }
        return (try? JSONDecoder().decode([AvailableModel].self, from: data)) ?? []
    }
    static func save(_ models: [AvailableModel], provider: ProviderKind) {
        if let data = try? JSONEncoder().encode(models) { UserDefaults.standard.set(data, forKey: "modelCatalog-\(provider.rawValue)") }
    }
    static func fetch(provider: ProviderKind, key: String, baseURL: String) async throws -> [AvailableModel] {
        guard !key.isEmpty else { throw LLMError.missingAPIKey(provider.displayName) }
        let base = provider == .anthropic ? "https://api.anthropic.com/v1" : provider == .openAI ? "https://api.openai.com/v1" : baseURL
        guard var components = URLComponents(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/models"),
              components.scheme == "https" || (components.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(components.host ?? "")),
              components.user == nil, components.password == nil else { throw KuraError.message("Use an HTTPS API URL, or HTTP on localhost.") }
        var models: [AvailableModel] = [], cursor: String?, seen = Set<String>()
        repeat {
            try Task.checkCancellation()
            components.queryItems = provider == .anthropic ? [URLQueryItem(name: "limit", value: "1000")] + (cursor.map { [URLQueryItem(name: "after_id", value: $0)] } ?? []) : nil
            guard let url = components.url else { throw KuraError.message("Invalid model-list URL.") }
            var request = URLRequest(url: url); request.timeoutInterval = 30
            if provider == .anthropic {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw KuraError.message("Model refresh failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). Check the saved key and account access.")
            }
            let page = try parse(data); models += page.models; cursor = page.next
            if let cursor, !seen.insert(cursor).inserted { throw KuraError.message("Provider repeated a model-list page.") }
        } while cursor != nil
        var unique = Set<String>()
        return models.filter { unique.insert($0.id).inserted && isTextModel($0.id, provider: provider) }.sorted { $0.id < $1.id }
    }
    // /v1/models lists embeddings, audio, image, and moderation endpoints that
    // cannot answer chat requests; offering them breaks every answer silently.
    static func isTextModel(_ id: String, provider: ProviderKind) -> Bool {
        switch provider {
        case .anthropic: return id.hasPrefix("claude")
        case .openAICompatible, .ollama: return true
        case .openAI:
            let family = id.hasPrefix("gpt-") || id.hasPrefix("chatgpt-")
                || id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4")
            let nonChat = ["embed", "dall-e", "whisper", "tts", "audio", "realtime",
                           "image", "moderation", "sora", "transcribe", "search", "computer-use"]
            return family && !nonChat.contains { id.contains($0) }
        }
    }
}
