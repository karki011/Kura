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

enum SpokenQuestion {
    static func matches(_ text: String) -> Bool {
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
