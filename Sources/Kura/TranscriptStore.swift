import Foundation

struct TranscriptLine: Identifiable, Equatable, Codable, Sendable {
    var id = UUID()
    var speaker: String
    var text: String
    var isFinal: Bool
    var timestamp = Date()
    var source: String = "speech"
    var suggestedName: String?
    init(id: UUID = UUID(), speaker: String, text: String, isFinal: Bool = true,
         timestamp: Date = Date(), source: String = "speech", suggestedName: String? = nil) {
        self.id = id; self.speaker = speaker; self.text = text; self.isFinal = isFinal
        self.timestamp = timestamp; self.source = source; self.suggestedName = suggestedName
    }
    enum CodingKeys: String, CodingKey { case id, speaker, text, isFinal, timestamp, source, suggestedName }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        speaker = try c.decode(String.self, forKey: .speaker)
        text = try c.decode(String.self, forKey: .text)
        isFinal = try c.decodeIfPresent(Bool.self, forKey: .isFinal) ?? true
        timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? .distantPast
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? (speaker == "AI" ? "assistant" : "speech")
        suggestedName = try c.decodeIfPresent(String.self, forKey: .suggestedName)
    }
}

enum ConversationContext {
    static func recent(_ lines: [TranscriptLine], maxChars: Int = 14000) -> String {
        guard maxChars > 0 else { return "" }
        var remaining = maxChars; var selected: [String] = []
        for line in lines.reversed() where !line.text.isEmpty {
            let part = String("\(line.speaker): \(line.text)".suffix(remaining))
            selected.append(part); remaining -= part.count + 1
            if remaining <= 0 { break }
        }
        return selected.reversed().joined(separator: "\n")
    }
    static func chunks(_ lines: [TranscriptLine], maxChars: Int = 14000) -> [String] {
        guard maxChars > 100 else { return [] }
        var result: [String] = []; var current = ""
        for line in lines where !line.text.isEmpty && line.source != "assistant" && line.source != "prompt" {
            let prefix = "[\(line.id.uuidString)] \(line.speaker): "
            var rest = line.text[...]
            while !rest.isEmpty {
                let part = String(rest.prefix(max(1, maxChars - prefix.count - 1)))
                rest = rest.dropFirst(part.count)
                let rendered = prefix + part + "\n"
                if current.count + rendered.count > maxChars, !current.isEmpty { result.append(current); current = "" }
                current += rendered
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

@MainActor
final class TranscriptStore: ObservableObject {
    @Published private(set) var lines: [TranscriptLine] = []
    var onLineFinalized: ((TranscriptLine) -> Void)?
    func replace(_ lines: [TranscriptLine]) { self.lines = lines }
    func updatePartial(_ text: String, speaker: String) {
        if let i = lines.lastIndex(where: { $0.speaker == speaker && !$0.isFinal && $0.source == "speech" }) {
            lines[i].text = text
        } else if !text.isEmpty { lines.append(TranscriptLine(speaker: speaker, text: text, isFinal: false)) }
    }
    func commitFinal(_ text: String, speaker: String) {
        if let i = lines.lastIndex(where: { $0.speaker == speaker && !$0.isFinal && $0.source == "speech" }) {
            lines[i].text = text; lines[i].isFinal = true
            if !text.isEmpty { onLineFinalized?(lines[i]) }
        } else { appendFinal(text, speaker: speaker) }
    }
    func appendFinal(_ text: String, speaker: String, source: String = "speech", timestamp: Date = Date(), suggestedName: String? = nil) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let line = TranscriptLine(speaker: speaker, text: text, timestamp: timestamp, source: source, suggestedName: suggestedName)
        lines.append(line); onLineFinalized?(line)
    }
    func beginStreaming(speaker: String) -> UUID {
        let line = TranscriptLine(speaker: speaker, text: "", isFinal: false, source: "assistant")
        lines.append(line); return line.id
    }
    func appendDelta(_ delta: String, to id: UUID) {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[i].text += delta
    }
    func finalize(id: UUID, fallback: String? = nil) {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
        if lines[i].text.isEmpty, let fallback { lines[i].text = fallback }
        lines[i].isFinal = true
    }
    func finishOpenLines() { for i in lines.indices { lines[i].isFinal = true } }
    func clear() { lines = [] }
    func recentContext(maxChars: Int = 14000) -> String { ConversationContext.recent(lines, maxChars: maxChars) }
}
