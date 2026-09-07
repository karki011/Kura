// TranscriptStore — rolling transcript of the conversation (system audio "Them" + push-to-talk "You").
import Foundation

struct TranscriptLine: Identifiable, Equatable {
    let id = UUID()
    let speaker: String // "Them" or "You"
    var text: String
    var isFinal: Bool
}

@MainActor
final class TranscriptStore: ObservableObject {
    @Published private(set) var lines: [TranscriptLine] = []
    var onLineFinalized: ((TranscriptLine) -> Void)?
    private let cap = 500

    /// Fuzzy duplicate check: identical after lowercasing + stripping punctuation,
    /// or near-prefix (one is ≥80% of the other). Rotation re-recognitions differ
    /// invisibly (trailing "?", casing), so exact matching misses them.
    private func isDupe(_ a: String, of b: String) -> Bool {
        let na = Self.normalized(a), nb = Self.normalized(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb { return true }
        let shorter = na.count <= nb.count ? na : nb
        let longer = na.count <= nb.count ? nb : na
        return shorter.count >= 15
            && longer.hasPrefix(shorter)
            && Double(shorter.count) / Double(longer.count) > 0.8
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func latestOpenLineIndex(for speaker: String) -> Int? {
        lines.indices.reversed().first { lines[$0].speaker == speaker && !lines[$0].isFinal }
    }

    /// Live partial result: rewrites the current open line for that speaker,
    /// or opens a new line if the last one is finalized / another speaker's.
    func updatePartial(_ text: String, speaker: String) {
        // Rotation re-hears the previous window's tail — don't show a partial
        // that repeats this speaker's last final line.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           let prev = lines.last(where: { $0.speaker == speaker && $0.isFinal }),
           isDupe(trimmed, of: prev.text) {
            return
        }
        if let index = latestOpenLineIndex(for: speaker) {
            lines[index].text = text
        } else {
            append(TranscriptLine(speaker: speaker, text: text, isFinal: false))
        }
    }

    /// Commits the current open line; the next partial opens a fresh one.
    func commitFinal(_ text: String, speaker: String) {
        // Recognition rotation can re-commit the tail of the previous window —
        // drop a line that repeats that speaker's previous final line.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           let prev = lines.last(where: { $0.speaker == speaker && $0.isFinal }),
           isDupe(trimmed, of: prev.text) {
            if let index = latestOpenLineIndex(for: speaker) {
                lines.remove(at: index)
            }
            return
        }
        let finalized: TranscriptLine
        if let index = latestOpenLineIndex(for: speaker) {
            lines[index].text = text
            lines[index].isFinal = true
            finalized = lines[index]
        } else {
            let line = TranscriptLine(speaker: speaker, text: text, isFinal: true)
            append(line)
            finalized = line
        }
        onLineFinalized?(finalized)
    }

    func appendFinal(_ text: String, speaker: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        append(TranscriptLine(speaker: speaker, text: trimmed, isFinal: true))
        if let line = lines.last { onLineFinalized?(line) }
    }

    // Streaming-line API for inline AI answers.
    func beginStreaming(speaker: String) -> UUID {
        let line = TranscriptLine(speaker: speaker, text: "", isFinal: false)
        append(line)
        return line.id
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

    func clear() { lines = [] }

    /// "Them: ...\nYou: ..." oldest→newest, newest lines kept within maxChars.
    func recentContext(maxChars: Int = 4000) -> String {
        var picked: [String] = []
        var total = 0
        for line in lines.reversed() where !line.text.isEmpty {
            let rendered = "\(line.speaker): \(line.text)"
            guard total + rendered.count <= maxChars else { break }
            picked.append(rendered)
            total += rendered.count + 1
        }
        return picked.reversed().joined(separator: "\n")
    }

    private func append(_ line: TranscriptLine) {
        lines.append(line)
        if lines.count > cap { lines.removeFirst(lines.count - cap) }
    }
}
