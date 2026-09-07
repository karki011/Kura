import AppKit
import ScreenCaptureKit
import Vision

struct MeetingWindowChoice: Identifiable {
    let window: SCWindow
    var id: CGWindowID { window.windowID }
    var title: String { "\(window.owningApplication?.applicationName ?? "App") — \(window.title ?? "Meeting window")" }
}

enum SpeakerCueParser {
    // Only explicit active-speaker phrases qualify. A visible participant name alone is not evidence.
    static func suggestion(in lines: [String]) -> String? {
        for line in lines {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in ["Speaking: ", "Active speaker: "] where value.lowercased().hasPrefix(prefix.lowercased()) {
                let name = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty && name.count <= 60 { return name }
            }
            if value.lowercased().hasSuffix(" is speaking") {
                let name = String(value.dropLast(12))
                if !name.isEmpty && name.count <= 60 { return name }
            }
        }
        return nil
    }
    static func captionSuggestion(for speech: String, lines: [String]) -> String? {
        let words = Set(speech.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 })
        guard words.count >= 4 else { return nil }
        for (index, line) in lines.enumerated() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            let caption = parts.count == 2 ? parts[1] : line
            let captionWords = Set(caption.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 })
            guard words.intersection(captionWords).count >= 4,
                  Double(words.intersection(captionWords).count) / Double(words.count) >= 0.65 else { continue }
            let candidate = parts.count == 2 ? parts[0] : (index > 0 ? lines[index - 1] : "")
            let name = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            let excluded = ["captions", "transcript", "participants", "chat", "you", "unknown speaker", "closed captions", "live captions"]
            guard !name.isEmpty, name.count <= 50, name.split(separator: " ").count <= 4,
                  !excluded.contains(name.lowercased()), name.rangeOfCharacter(from: .decimalDigits) == nil else { continue }
            return name
        }
        return nil
    }
}

@MainActor
final class MeetingWindowObserver: ObservableObject {
    @Published var windows: [MeetingWindowChoice] = []
    @Published var selectedID: CGWindowID?
    @Published var observing = false
    @Published var status = "Choose your Zoom, Meet, Teams, or other meeting window."
    @Published var visibleText = ""
    @Published var suggestion: String?
    private var suggestionDate = Date.distantPast
    private var observationDate = Date.distantPast
    private var task: Task<Void, Never>?
    private var generation = UUID()
    var recentSpeakerSuggestion: String? { Date().timeIntervalSince(suggestionDate) < 3 ? suggestion : nil }
    func suggestedName(for speech: String) -> String? {
        guard observing, Date().timeIntervalSince(observationDate) < 4 else { return nil }
        return SpeakerCueParser.captionSuggestion(for: speech, lines: visibleText.components(separatedBy: .newlines)) ?? recentSpeakerSuggestion
    }
    func refresh() {
        if Config.preview { status = "Preview: no real windows are captured. The live app requests Screen Recording permission here."; return }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                windows = content.windows.filter { $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier && $0.frame.width > 200 && $0.frame.height > 100 && !($0.title ?? "").isEmpty }.map { MeetingWindowChoice(window: $0) }
                status = windows.isEmpty ? "Open your meeting window, then refresh." : "Only the window you choose will be observed."
            } catch { status = "Allow Screen Recording in System Settings, then refresh. \(error.localizedDescription)" }
        }
    }
    func start() {
        guard let choice = windows.first(where: { $0.id == selectedID }) else { status = "Choose a meeting window first."; return }
        stop(); generation = UUID(); let token = generation
        observing = true; status = "Observing \(choice.window.owningApplication?.applicationName ?? "meeting") locally"
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == token else { return }
                do {
                    let filter = SCContentFilter(desktopIndependentWindow: choice.window)
                    let config = SCStreamConfiguration()
                    config.width = min(1600, Int(choice.window.frame.width * 2))
                    config.height = Int(Double(config.width) * choice.window.frame.height / choice.window.frame.width)
                    config.showsCursor = false
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    let text = try await Self.recognize(image)
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.visibleText = text.joined(separator: "\n")
                    self.observationDate = Date()
                    self.suggestion = SpeakerCueParser.suggestion(in: text)
                    if self.suggestion != nil { self.suggestionDate = Date() }
                    try await Task.sleep(for: .seconds(2))
                } catch is CancellationError { return }
                catch { self.status = "Window observation paused: \(error.localizedDescription)"; self.observing = false; self.suggestion = nil; return }
            }
        }
    }
    nonisolated private static func recognize(_ image: CGImage) async throws -> [String] {
        try await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first }.filter { $0.confidence > 0.8 }.map(\.string)
        }.value
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; observing = false
        suggestion = nil; visibleText = ""; status = "Window observation is off"
    }
}
