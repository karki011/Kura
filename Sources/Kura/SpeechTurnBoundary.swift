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
        return value.hasSuffix("?") || [
            "what ", "how ", "why ", "when ", "where ", "which ", "who ",
            "can you ", "could you ", "would you ", "should we ", "do you ",
            "does ", "is there ", "are there ", "explain ", "tell me ",
            "describe ", "walk me ", "give me "
        ].contains { normalized.hasPrefix($0) }
    }
}
