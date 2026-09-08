import SwiftUI
import AppKit

struct ContextView: View {
    @ObservedObject var viewModel: OverlayViewModel
    var onDone: () -> Void
    @State private var packName = ""
    @State private var preview: ContextAttachment?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { VStack(alignment: .leading, spacing: 4) { Text("Give Kura the background").font(.title2.bold()); Text("Used for this meeting. Reuse it elsewhere only when you choose.").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Done", action: onDone).keyboardShortcut(.defaultAction) }
            TextField("Meeting goal", text: Binding(get: { viewModel.current.goal }, set: { value in viewModel.editCurrent { $0.goal = value } })).textFieldStyle(.roundedBorder)
            HStack { Text("Notes").font(.headline); Spacer(); Button("Paste notes", systemImage: "doc.on.clipboard") { if let text = NSPasteboard.general.string(forType: .string) { viewModel.editCurrent { $0.context += ($0.context.isEmpty ? "" : "\n\n") + text } } } }
            TextEditor(text: Binding(get: { viewModel.current.context }, set: { value in viewModel.editCurrent { $0.context = value } }))
                .font(.system(size: 14)).padding(8).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10)).frame(height: 160)
            HStack { Text("Attachments").font(.headline); Spacer(); Button("Add files…", systemImage: "paperclip") { viewModel.chooseFiles() }.disabled(viewModel.importing) }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(viewModel.current.attachments) { item in
                        HStack {
                            Image(systemName: "doc.text").foregroundStyle(KuraStyle.accent)
                            VStack(alignment: .leading) { Text(item.name).lineLimit(1); Text(item.warning.isEmpty ? "Ready · \(item.text.count.formatted()) characters" : item.warning).font(.caption).foregroundStyle(item.warning.isEmpty ? Color.secondary : Color.orange) }
                            Spacer(); Button("Preview") { preview = item }
                            Button { viewModel.editCurrent { $0.attachments.removeAll { $0.id == item.id } } } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Remove \(item.name)")
                        }.padding(8).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if viewModel.current.attachments.isEmpty { Text("PDFs, Markdown, and plain text · up to 20 MB per file").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }.frame(maxHeight: 110)
            if viewModel.current.contextIsTrimmed { Text("This meeting exceeds the AI background limit. The first 40,000 characters of goal, notes, and attachments will be included. Remove or shorten material to include later files.").font(.caption).foregroundStyle(.orange) }
            Divider()
            HStack {
                Menu("Use a context pack") { ForEach(viewModel.meetings.packs) { pack in Button(pack.name) { viewModel.applyPack(pack) } } }.disabled(viewModel.meetings.packs.isEmpty)
                TextField("Save as a reusable pack…", text: $packName).textFieldStyle(.roundedBorder)
                Button("Save pack") { viewModel.saveContextPack(packName); packName = "" }.disabled(packName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !viewModel.lastError.isEmpty { Text(viewModel.lastError).font(.caption).foregroundStyle(.orange) }
        }.padding(22).frame(width: 570).sheet(item: $preview) { AttachmentPreview(item: $0) }
    }
}
struct AttachmentPreview: View {
    let item: ContextAttachment
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(item.name).font(.headline); Spacer(); Button("Done") { dismiss() } }
            if !item.warning.isEmpty { Text(item.warning).font(.caption).foregroundStyle(.orange) }
            ScrollView { Text(item.text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(20).frame(width: 540, height: 430)
    }
}
struct CaptureSetupView: View {
    @ObservedObject var model: OverlayViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("includeMicrophone") private var includeMicrophone = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Connect your meeting").font(.title2.bold()); Spacer(); Button("Done") { dismiss() } }
            Text("System audio captures what you hear. Use a headset and get the participants’ agreement before transcribing.").font(.callout).foregroundStyle(.secondary)
            Toggle("Include my microphone as “You”", isOn: $includeMicrophone).disabled(model.alwaysOnActive)
            Text("Applies when you start listening. Your microphone uses Apple speech recognition. A headset helps prevent remote voices being captured twice.").font(.caption).foregroundStyle(.secondary)
            GroupBox("Speaker labels") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(TranscriptionEngine.saved == .fluid ? "On-device · live speaker labels" : "Apple Speech · unnamed remote speakers").font(.headline)
                    Text(TranscriptionEngine.saved == .fluid ? "Remote voices get tentative live labels from on-device models (up to 4 speakers). Names need confirmation; you can rename speakers in the transcript." : "Apple Speech does not separate remote voices. Choose the on-device speaker labels option in Settings for live labels.").font(.caption).foregroundStyle(.secondary)
                    Button("Transcription settings…") {
                        UserDefaults.standard.set("Audio", forKey: "settingsTab")
                        NotificationCenter.default.post(name: .kuraOpenSettings, object: nil)
                    }
                }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Optional window observation") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Read visible meeting text on this Mac to suggest speaker names. Images are not saved or sent to an AI provider. Screen Recording permission is needed.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Picker("Window", selection: Binding(get: { model.observer.selectedID }, set: { model.observer.selectedID = $0 })) {
                            Text("Choose a window").tag(Optional<CGWindowID>.none)
                            ForEach(model.observer.windows) { window in Text(window.title).tag(Optional(window.id)) }
                        }.disabled(model.observer.observing)
                        Button("Refresh") { model.observer.refresh() }.disabled(model.observer.observing)
                    }
                    HStack {
                        Button(model.observer.observing ? "Stop observation" : "Observe selected window") { if model.observer.observing { model.observer.stop() } else { model.observer.start() } }
                            .disabled(!model.observer.observing && model.observer.selectedID == nil)
                        if model.observer.observing { Image(systemName: "eye.fill").foregroundStyle(KuraStyle.accent) }
                    }
                    Text(model.observer.status).font(.caption).foregroundStyle(.secondary)
                    Text("Turn on your meeting’s captions for better name suggestions. Kura matches visible caption text or explicit speaking labels; confirm each name in the transcript. Gallery borders and overlapping speech may not provide a reliable cue.").font(.caption).foregroundStyle(.secondary)
                    if !model.observer.visibleText.isEmpty {
                        DisclosureGroup("Visible text preview") { ScrollView { Text(model.observer.visibleText).textSelection(.enabled).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 90) }
                    }
                }.padding(6)
            }
            Text("With microphone inclusion off, use the dictation button to capture your voice. System audio can also include sounds from other apps.").font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width: 590)
    }
}
extension Notification.Name { static let kuraOpenContext = Notification.Name("kuraOpenContext") }
