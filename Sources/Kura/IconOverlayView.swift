import SwiftUI

/// Comic-style speech bubble: rounded body with a tail pointing down-left at the icon.
private struct BubbleShape: Shape {
    var tailX: CGFloat = 30
    func path(in rect: CGRect) -> Path {
        let corner: CGFloat = 14
        let tailH: CGFloat = 10, tailW: CGFloat = 16
        var p = Path()
        let body = CGRect(x: 0, y: 0, width: rect.width, height: rect.height - tailH)
        p.addRoundedRect(in: body, cornerSize: CGSize(width: corner, height: corner))
        p.move(to: CGPoint(x: tailX + tailW, y: body.maxY - 1))
        p.addLine(to: CGPoint(x: tailX + 4, y: rect.maxY))
        p.addLine(to: CGPoint(x: tailX - 4, y: body.maxY - 1))
        p.closeSubpath()
        return p
    }
}

/// Icon-only floating mode: the Kura icon "speaks" the latest transcript line
/// or streaming answer through a tailed bubble. No card chrome — the panel
/// stays transparent; tint/color scheme come from OverlayView's KuraAppearance.
struct IconOverlayView: View {
    @ObservedObject var viewModel: OverlayViewModel

    private var listening: Bool { viewModel.alwaysOnActive || viewModel.status == .listening }
    private var bubbleText: String {
        let lines = viewModel.current.lines
        if viewModel.status == .streaming, let answer = lines.last(where: { $0.source == "assistant" }) {
            return answer.text.isEmpty ? "Kura is thinking…" : answer.text
        }
        if let partial = lines.last(where: { !$0.isFinal && !$0.text.isEmpty }) { return partial.text }
        if let final = lines.last(where: { $0.isFinal && !$0.text.isEmpty }) { return final.text }
        return listening ? "Listening…" : "Paused — tap the icon to open Kura"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(MarkdownText.attributed(bubbleText))
                .font(.system(size: 12))
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background {
                    BubbleShape()
                        .fill(.regularMaterial)
                        .overlay { BubbleShape().fill(KuraStyle.accent.opacity(0.10)) }
                }
                .overlay { BubbleShape().stroke(KuraStyle.accent.opacity(0.45), lineWidth: 1) }
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                .padding(.leading, 22)
                .accessibilityLabel("Latest: \(bubbleText)")
            Button { viewModel.expandFromIcon() } label: {
                KuraLogo(size: 40)
                    .overlay {
                        if listening {
                            Circle().stroke(KuraStyle.accent, lineWidth: 2).padding(-3)
                        }
                    }
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Open Kura workspace")
            .accessibilityLabel("Open Kura workspace")
            .padding(.leading, 8).padding(.top, 2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .contentShape(Rectangle())
        .onTapGesture { viewModel.expandFromIcon() }
    }
}
