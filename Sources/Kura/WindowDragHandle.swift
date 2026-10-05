import AppKit
import SwiftUI

struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }
    func updateNSView(_ nsView: WindowDragView, context: Context) {}
}

final class WindowDragView: NSView {
    private var dragStart: NSPoint?
    private var originalFrame: NSRect?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "Drag to move Kura"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Move Kura window")
        setAccessibilityHelp("Drag this handle to move the window")
    }

    required init?(coder: NSCoder) { return nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStart = window.convertPoint(toScreen: event.locationInWindow)
        originalFrame = window.frame
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragStart, let originalFrame else { return }
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(NSPoint(x: originalFrame.origin.x + pointer.x - dragStart.x,
                                      y: originalFrame.origin.y + pointer.y - dragStart.y))
    }

    override func mouseUp(with event: NSEvent) {
        if let window, let originalFrame, originalFrame != window.frame {
            window.saveFrame(usingName: "KuraWorkspace")
            if Config.debug { NSLog("[windowdrag] %@ -> %@", NSStringFromRect(originalFrame), NSStringFromRect(window.frame)) }
        }
        dragStart = nil; originalFrame = nil
        NSCursor.openHand.set()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setFill()
        for x in [-3.0, 3.0] {
            for y in [-5.0, 0.0, 5.0] {
                NSBezierPath(ovalIn: NSRect(x: bounds.midX + x - 1.5,
                                           y: bounds.midY + y - 1.5, width: 3, height: 3)).fill()
            }
        }
    }
}
