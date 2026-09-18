// ShareHideWatcher — hides every Kura window while a meeting app reports an active
// screen share, then restores them when the share ends.
//
// sharingType = .none only protects against capture paths that consult the window
// server. Zoom's GPU-accelerated capture reads the composited framebuffer and shows
// capture-excluded windows anyway — the only guaranteed invisibility is not being
// on screen. Detection reads the meeting app's Accessibility tree for strings that
// only exist while the user is presenting (Zoom: "Stop share"/"You are screen
// sharing", Meet-in-browser: "You're presenting to everyone", …). Menu bars are
// skipped: they contain disabled "Stop share" menu items even when not sharing.
import AppKit
import ApplicationServices

private let nativeSharePhrases = ["stop share", "you are screen sharing", "stop sharing"]
private let browserSharePhrases = ["you're presenting to everyone", "you are presenting to everyone", "stop presenting"]
private let nativeShareBundleIDs: Set<String> = [
    "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2",
    "com.cisco.webexmeetings", "com.webex.meetingmanager",
]
private let browserShareBundleIDs: Set<String> = [
    "com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.brave.Browser",
]

@MainActor
final class ShareHideWatcher {
    static let shared = ShareHideWatcher()

    /// Order out all visible app windows; returns whether anything was hidden.
    var hideWindows: (() -> Bool)?
    /// Restore windows hidden by an earlier hideWindows call. `restorePanel` is false
    /// when the user deliberately showed the overlay mid-share — it is already up.
    var restoreWindows: ((_ restorePanel: Bool) -> Void)?

    private(set) var sharingActive = false
    private var timer: Timer?
    private var scanning = false
    private var hiddenByShare = false
    /// The user explicitly showed the overlay during this share; don't hide it again.
    private var userOverride = false

    private var enabled: Bool {
        UserDefaults.standard.object(forKey: "hideWhileSharing") as? Bool ?? true
    }

    func start() {
        guard !Config.preview, !Config.debug, timer == nil else { return }
        UserDefaults.standard.register(defaults: ["hideWhileSharing": true])
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    /// Called whenever the user explicitly shows the overlay (hotkey/menu).
    func noteManualShow() {
        if sharingActive { userOverride = true }
    }

    private func poll() {
        guard !scanning else { return }
        guard enabled, AXIsProcessTrusted() else { apply(active: false); return }
        let targets: [(pid: pid_t, native: Bool)] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, let id = app.bundleIdentifier else { return nil }
            if nativeShareBundleIDs.contains(id) { return (app.processIdentifier, true) }
            if browserShareBundleIDs.contains(id) { return (app.processIdentifier, false) }
            return nil
        }
        guard !targets.isEmpty else { apply(active: false); return }
        scanning = true
        Task.detached(priority: .utility) { [weak self] in
            var found = false
            for target in targets {
                let phrases = target.native ? nativeSharePhrases : browserSharePhrases
                if Self.shareIndicatorVisible(pid: target.pid, phrases: phrases) { found = true; break }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.scanning = false
                self.apply(active: found)
            }
        }
    }

    private func apply(active: Bool) {
        guard active != sharingActive else { return }
        sharingActive = active
        if active {
            userOverride = false
            hiddenByShare = hideWindows?() ?? false
        } else {
            if hiddenByShare { restoreWindows?(!userOverride) }
            hiddenByShare = false
            userOverride = false
        }
    }

    /// Walks the app's AX tree looking for a phrase that only exists while presenting.
    /// AXValue alone misses button labels, so AXTitle/AXDescription are read too.
    /// Bounded depth/node counts keep a runaway WebView tree from stalling the loop.
    nonisolated static func shareIndicatorVisible(pid: pid_t, phrases: [String], maxDepth: Int = 16, maxNodes: Int = 4000) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var visited = 0
        var found = false
        func walk(_ element: AXUIElement, _ depth: Int) {
            guard !found, depth <= maxDepth, visited < maxNodes else { return }
            visited += 1
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &roleRef) == .success,
               roleRef as? String == "AXMenuBar" { return }
            for attr in ["AXTitle", "AXDescription", "AXValue"] {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success,
                   let string = value as? String {
                    let lower = string.lowercased()
                    if phrases.contains(where: { lower.contains($0) }) { found = true; return }
                }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                for child in list { walk(child, depth + 1) }
            }
        }
        walk(app, 0)
        return found
    }
}
