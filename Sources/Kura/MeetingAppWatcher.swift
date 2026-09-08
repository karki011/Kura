import AppKit
import ApplicationServices

struct MeetingAppChoice: Identifiable {
    let pid: pid_t
    let name: String
    var id: pid_t { pid }
}

/// Pure evidence accumulator for screen↔voice binding. A display name binds to a
/// diarization slot only after the same name coincides with the SAME slot at least
/// `required` times; evidence split across slots (or tied between slots) never binds.
struct SpeakerBindingTracker {
    private var counts: [String: [String: Int]] = [:]
    mutating func record(name: String, slot: String) {
        counts[name, default: [:]][slot, default: 0] += 1
    }
    func count(name: String, slot: String) -> Int { counts[name]?[slot] ?? 0 }
    func confirmedSlot(for name: String, required: Int = 2) -> String? {
        guard let slots = counts[name] else { return nil }
        let winners = slots.filter { $0.value >= required }
        guard winners.count == 1 else { return nil }
        return winners.keys.first
    }
    mutating func clear(name: String) { counts.removeValue(forKey: name) }
    mutating func reset() { counts = [:] }
}

/// Reads a meeting app's UI text through the Accessibility API instead of
/// screenshot OCR. Same suggestion contract as MeetingWindowObserver so both
/// feed SpeakerCueParser unchanged.
@MainActor
final class MeetingAppWatcher: ObservableObject {
    @Published var apps: [MeetingAppChoice] = []
    @Published var selectedPID: pid_t?
    @Published var observing = false
    @Published var status = "Choose your Zoom, Teams, Meet, or other meeting app."
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
        if Config.preview { status = "Preview: no real apps are read. The live app uses Accessibility access here."; return }
        let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let visiblePIDs = Set(windowInfo.compactMap { info -> pid_t? in
            guard (info[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return info[kCGWindowOwnerPID as String] as? pid_t
        })
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && visiblePIDs.contains($0.processIdentifier) }
            .compactMap { app in app.localizedName.map { MeetingAppChoice(pid: app.processIdentifier, name: $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        status = apps.isEmpty ? "Open your meeting app, then refresh." : "Only the app you choose will be read."
    }
    func start() {
        guard let choice = apps.first(where: { $0.id == selectedPID }) else { status = "Choose a meeting app first."; return }
        guard AXIsProcessTrusted() else {
            status = "Allow Accessibility in System Settings, then start again."
            PermissionManager.shared.requestAndOpen(.accessibility)
            return
        }
        stop(); generation = UUID(); let token = generation
        observing = true; status = "Reading \(choice.name) locally"
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == token else { return }
                let lines = await Task.detached(priority: .utility) { Self.harvestLines(pid: choice.pid) }.value
                guard self.generation == token, !Task.isCancelled else { return }
                self.visibleText = lines.joined(separator: "\n")
                self.observationDate = Date()
                self.suggestion = SpeakerCueParser.suggestion(in: lines)
                if self.suggestion != nil { self.suggestionDate = Date() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    /// Walks the app's AX tree off the main thread, collecting short AXValue
    /// strings (static text, captions, labels). Bounded depth/node/string counts
    /// keep a runaway WebView tree from stalling the loop.
    nonisolated static func harvestLines(pid: pid_t, maxDepth: Int = 14, maxNodes: Int = 3000, maxStrings: Int = 400) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        var lines: [String] = []
        var seen = Set<String>()
        var visited = 0
        func walk(_ element: AXUIElement, _ depth: Int) {
            guard depth <= maxDepth, visited < maxNodes, lines.count < maxStrings else { return }
            visited += 1
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXValue" as CFString, &value) == .success, let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed.count <= 200, seen.insert(trimmed).inserted { lines.append(trimmed) }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &children) == .success, let list = children as? [AXUIElement] {
                for child in list { walk(child, depth + 1) }
            }
        }
        walk(app, 0)
        return lines
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; observing = false
        suggestion = nil; visibleText = ""; status = "App observation is off"
    }
}
