// PointerCursor — makes custom SwiftUI controls advertise that they are interactive on macOS.
import SwiftUI
import AppKit

private struct PointingHandCursorModifier: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        content.onHover { isHovering in
            if isHovering && enabled {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

extension View {
    /// Applies the familiar macOS hand cursor to a control or a custom tappable region.
    func pointingHandCursor(enabled: Bool = true) -> some View {
        modifier(PointingHandCursorModifier(enabled: enabled))
    }
}
