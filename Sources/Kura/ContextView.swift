// ContextView — per-session context editor: notes + PDF/text attachment, feeds every LLM call this session.
import SwiftUI
import AppKit

struct ContextView: View {
    @ObservedObject var viewModel: OverlayViewModel
    var onDone: () -> Void
    @State private var attachError = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What's this meeting about?")
                .font(.headline)
            Text("Only used for this session — cleared when you start a new one. Never shared between meetings.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $viewModel.sessionContext)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.3)))
                .overlay(
                    Group {
                        if viewModel.sessionContext.isEmpty {
                            Text("e.g. Discovery call with Acme Corp — they care about pricing, SSO, and a Q1 rollout. Attach their brief if you have it…")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary.opacity(0.6))
                                .padding(12)
                                .allowsHitTesting(false)
                        }
                    },
                    alignment: .topLeading
                )

            HStack(spacing: 10) {
                Button("Attach PDF / Text…") { attach() }
                    .controlSize(.small)
                    .pointingHandCursor()
                if !attachError.isEmpty {
                    Text(attachError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Done") { onDone() }
                    .keyboardShortcut(.defaultAction)
                    .pointingHandCursor()
            }
        }
        .padding(16)
        .frame(width: 440, height: 300)
        .preferredColorScheme(.dark)
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .plainText, .text]
        panel.allowsMultipleSelection = false
        panel.sharingType = Config.debug ? .readOnly : .none
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try MeetingStore.extractText(from: url)
            let header = "\n\n--- Attached: \(url.lastPathComponent) ---\n"
            viewModel.sessionContext += header + text
            attachError = ""
        } catch {
            attachError = error.localizedDescription
        }
    }
}

extension Notification.Name {
    static let kuraOpenContext = Notification.Name("kuraOpenContext")
}
