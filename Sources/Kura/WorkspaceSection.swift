import SwiftUI

/// Shared by the workspace and auxiliary windows so appearance stays in sync.
struct KuraAppearance: ViewModifier {
    var chrome = true
    @AppStorage("themeMode") private var themeMode = "auto"
    @AppStorage("overlayOpacity") private var opacity = 0.92

    func body(content: Content) -> some View {
        content
            .background {
                if chrome {
                    ZStack {
                        Rectangle().fill(.regularMaterial.opacity(opacity))
                        // Scale the solid base with the slider too — a constant fill
                        // made even the lowest setting look opaque.
                        Color(nsColor: .windowBackgroundColor).opacity(opacity * 0.7)
                    }
                }
            }
            .tint(KuraStyle.accent)
            .preferredColorScheme(themeMode == "dark" ? .dark : themeMode == "light" ? .light : nil)
    }
}

struct WorkspaceSection<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
        .accessibilityElement(children: .contain)
    }
}
