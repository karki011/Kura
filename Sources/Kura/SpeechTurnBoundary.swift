import Foundation

/// Short-pause endpointing for Apple's cumulative partial results. All times are
/// monotonic, and repeated identical callbacks do not extend the stability wait.
struct SpeechTurnBoundary {
    private var text = ""
    private var changedAt: TimeInterval = 0
    private var audibleAt: TimeInterval = 0
    private var bufferAt: TimeInterval?

    mutating func observe(text: String, at time: TimeInterval) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value != self.text { self.text = value; changedAt = time }
    }

    mutating func observe(rms: Double, at time: TimeInterval) {
        bufferAt = time
        // Approximately -50 dBFS: conservative system-audio silence threshold.
        if rms >= 0.003 { audibleAt = time }
    }

    func shouldFinish(at time: TimeInterval) -> Bool {
        guard !text.isEmpty, let bufferAt else { return false }
        return time - changedAt >= 1.2 && time - audibleAt >= 0.9
            && time - bufferAt < 0.5 // A stalled capture is not a speech pause.
    }
}

/// Apple Speech revises the whole cumulative transcript until rotation, so long
/// monologues can silently rewrite what the user already read. Commit the stable
/// head of the partial incrementally; only the tail stays open to revision.
struct IncrementalTranscriptCommitter {
    private var committedCount = 0
    private var previous = ""

    /// Returns a chunk to commit as final once enough stable text accumulates.
    mutating func observe(_ text: String) -> String? {
        defer { previous = text }
        guard !previous.isEmpty else { return nil }
        let stableCount = text.commonPrefix(with: previous).count
        // Rare wholesale revision into committed territory: resync and move on.
        if stableCount < committedCount { committedCount = stableCount }
        guard stableCount - committedCount >= 120 else { return nil }
        let head = String(text.prefix(stableCount))
        // Cut at the last sentence end, else the last word boundary. Note:
        // .backwards + .regularExpression does not find the last match, so walk forward.
        var cut = head.endIndex
        var lastSentence: Range<String.Index>?
        var searchStart = head.startIndex
        while let r = head.range(of: #"[.!?]["']?\s"#, options: .regularExpression, range: searchStart..<head.endIndex) {
            lastSentence = r; searchStart = r.upperBound
        }
        if let lastSentence { cut = lastSentence.upperBound }
        else if let r = head.rangeOfCharacter(from: .whitespaces, options: .backwards) { cut = r.lowerBound }
        let chunk = String(head[..<cut]).dropFirst(committedCount).trimmingCharacters(in: .whitespaces)
        guard chunk.count >= 80 else { return nil }
        committedCount = head[..<cut].count
        return chunk
    }

    /// The still-revisable tail the UI should show as the live partial.
    func remainder(for text: String) -> String {
        guard committedCount <= text.count else { return text }
        return String(text.dropFirst(committedCount)).trimmingCharacters(in: .whitespaces)
    }
}

enum SpokenQuestion {    static func matches(_ text: String) -> Bool {
        let value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let words = value.split { !$0.isLetter && !$0.isNumber }
        guard words.count >= 3 else { return false }
        let normalized = words.joined(separator: " ")
        if value.hasSuffix("?") || [
            "what ", "how ", "why ", "when ", "where ", "which ", "who ",
            "can you ", "could you ", "would you ", "should we ", "do you ",
            "does ", "is there ", "are there ", "explain ", "tell me ",
            "describe ", "walk me ", "give me ",
            "design ", "write ", "draft ", "create ", "build ", "summarize ",
            "list ", "compare ", "define ", "calculate ", "outline ", "sketch ",
            "show me ", "help me "
        ].contains(where: { normalized.hasPrefix($0) }) { return true }
        // Transcription drops question marks and real questions often start with
        // a preamble ("hey team, quick question — what is …"), so also match
        // question phrases anywhere in the line.
        return [
            "what is", "what are", "what was", "what were", "what do", "what does",
            "what did", "what can", "what could", "what should", "what would",
            "how do", "how does", "how did", "how can", "how could", "how should",
            "how would", "how much", "how many", "how long",
            "why is", "why are", "why do", "why does", "why did",
            "when is", "when are", "when do", "when does", "when did", "when will",
            "where is", "where are", "where do", "where does", "where should",
            "which is", "which are", "which one", "which should",
            "who is", "who are", "who will",
            "can you", "could you", "would you", "should we", "do you",
            "does anyone", "is there", "are there",
            "tell me", "walk me through", "give me"
        ].contains { normalized.contains($0) }
    }
}
