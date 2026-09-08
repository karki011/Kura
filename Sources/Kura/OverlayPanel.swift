// OverlayPanel — borderless, non-activating NSPanel excluded from screen capture (sharingType = .none).
import AppKit
import SwiftUI

@MainActor
final class OverlayPanel: NSPanel {
    static let width: CGFloat = 1000

    init(viewModel: OverlayViewModel) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 440),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        // Critical stealth property: window is excluded from screen capture/sharing (unless debugging).
        sharingType = Config.debug ? .readOnly : .none
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        // Keep the native panel itself visually invisible. The SwiftUI card supplies
        // the rounded material treatment; a native shadow reveals a rectangular edge.
        hasShadow = false
        isMovableByWindowBackground = true
        minSize = NSSize(width: 900, height: 600)

        let hosting = NSHostingController(rootView: OverlayView(viewModel: viewModel))
        hosting.sizingOptions = []
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = .clear
        contentViewController = hosting
        setContentSize(NSSize(width: Self.width, height: 720))
        setFrameAutosaveName("KuraWorkspace")
        if !setFrameUsingName("KuraWorkspace") { positionTopCenter() }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func positionTopCenter() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        let x = vf.midX - frame.width / 2
        let y = vf.maxY - frame.height - 40
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
