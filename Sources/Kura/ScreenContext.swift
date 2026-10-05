import AppKit
@preconcurrency import ApplicationServices
import Combine
import ScreenCaptureKit
import Vision

struct ScreenContextSnapshot: Equatable, Sendable {
    let text: String
    let app: String
    let source: String
    let date: Date

    var meetingNote: String {
        "### Captured \(source) from \(app) · \(date.formatted(date: .abbreviated, time: .standard))\n\n\(text)"
    }

}

private struct ScreenContextTarget: Sendable {
    let pid: pid_t
    let app: String
    let x: Double
    let y: Double
}

@MainActor
final class ScreenContext: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var snapshot: ScreenContextSnapshot?
    @Published private(set) var status = "Press Control–Option–C in another app to capture context"
    @Published private(set) var capturing = false
    private var captureTask: Task<Void, Never>?
    private var captureID = UUID()
    private var shortcutMissing = false

    init(initialSnapshot: ScreenContextSnapshot? = nil) {
        snapshot = initialSnapshot
        enabled = initialSnapshot != nil
    }

    func captureFromHotkey(onCaptured: @escaping @MainActor (ScreenContextSnapshot) -> Void, onComplete: @escaping @MainActor () -> Void = {}) {
        guard !Config.preview else { status = "Use the live app to capture screen context"; return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let point = CGEvent(source: nil)?.location else {
            status = "Press Control–Option–C while the source app is active"
            onComplete()
            return
        }
        clear()
        guard AXIsProcessTrusted() else {
            status = "Kura’s Accessibility grant does not match this app. Refresh it in Settings → Permissions, then restart Kura."
            onComplete()
            return
        }
        let target = ScreenContextTarget(pid: app.processIdentifier, app: app.localizedName ?? "App", x: point.x, y: point.y)
        capturing = true; status = "Capturing context from \(target.app)…"
        let capture = UUID(); captureID = capture
        captureTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.captureID == capture { self.capturing = false; onComplete() }
            }
            do {
                let result = try await Task.detached(priority: .utility) { try Self.read(target) }.value
                try Task.checkCancellation()
                let text: String
                let source: String
                if let result {
                    text = result.0; source = result.1
                } else {
                    guard CGPreflightScreenCaptureAccess() else {
                        throw KuraError.message("No accessible text found. Allow Screen Recording for the OCR fallback, then press Control–Option–C again.")
                    }
                    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                    guard let window = content.windows.first(where: {
                        $0.owningApplication?.processID == target.pid && $0.windowLayer == 0 &&
                        $0.frame.contains(CGPoint(x: target.x, y: target.y))
                    }) else { throw KuraError.message("Point inside the source window and press Control–Option–C again") }
                    let config = SCStreamConfiguration()
                    config.width = min(2400, Int(window.frame.width * 2))
                    config.height = max(1, Int(Double(config.width) * window.frame.height / max(1, window.frame.width)))
                    config.showsCursor = false
                    let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
                    text = try await Task.detached(priority: .utility) {
                        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                        try VNImageRequestHandler(cgImage: image).perform([request])
                        return (request.results ?? []).compactMap { $0.topCandidates(1).first }
                            .filter { $0.confidence > 0.6 }.map(\.string).joined(separator: "\n")
                    }.value
                    source = "window text (OCR)"
                }
                try Task.checkCancellation()
                guard self.captureID == capture else { return }
                let bounded = Self.bounded(text)
                guard !bounded.isEmpty else { throw KuraError.message("No readable text found in that window") }
                let snapshot = ScreenContextSnapshot(text: bounded, app: target.app, source: source, date: Date())
                self.snapshot = snapshot
                self.enabled = true
                onCaptured(snapshot)
                self.status = "Captured \(source) from \(target.app) · Control–Option–C to capture more"
            } catch {
                guard self.captureID == capture, !Task.isCancelled else { return }
                self.status = "Capture failed: \(error.localizedDescription)"
            }
        }
    }

    func clear() {
        captureID = UUID(); captureTask?.cancel(); captureTask = nil; capturing = false
        snapshot = nil; enabled = false
        status = shortcutMissing ? "Control–Option–C is unavailable; another app may already use this shortcut" : "Press Control–Option–C in another app to capture context"
    }

    func stop() { clear() }

    func shortcutUnavailable() {
        shortcutMissing = true
        clear()
    }

    nonisolated static func bounded(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12000))
    }

    nonisolated private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    nonisolated private static func read(_ target: ScreenContextTarget) throws -> (String, String)? {
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        if let focused = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let element = unsafeDowncast(focused, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(element, 0.15)
            if attribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole {
                throw KuraError.message("Capture is unavailable while a secure text field is focused")
            }
            if let text = attribute(element, kAXSelectedTextAttribute) as? String, !bounded(text).isEmpty {
                return (bounded(text), "selected text")
            }
        }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(target.x), Float(target.y), &hit) == .success,
              let hit else { return nil }
        AXUIElementSetMessagingTimeout(hit, 0.15)
        guard attribute(hit, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else {
            throw KuraError.message("Capture is unavailable over a secure text field")
        }
        let strings = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
            .compactMap { attribute(hit, $0) as? String }.map(bounded).filter { !$0.isEmpty }
        let text = bounded(strings.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: "\n"))
        return text.isEmpty ? nil : (text, "text under pointer")
    }
}
