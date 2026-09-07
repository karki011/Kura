import SwiftUI
import AppKit

struct LocalSpeechSetupView: View {
    @AppStorage("localSpeechPython") private var python = ""
    @AppStorage("localWhisperCLI") private var whisper = ""
    @AppStorage("localWhisperModel") private var whisperModel = ""
    @AppStorage("localSpeakerModel") private var speakerModel = ""
    @State private var status = ""
    var body: some View {
        WorkspaceSection("Local model setup") {
            Text("Whisper transcribes; pyannote Community-1 separates voices. No paid speech API or subscription. Install the tools and download both models once, then select them below.")
                .font(.callout).foregroundStyle(.secondary)
            path("Python from your pyannote environment", value: $python)
            path("whisper-cli executable", value: $whisper)
            path("Whisper model (.bin)", value: $whisperModel)
            path("Community-1 model folder", value: $speakerModel, directory: true)
            HStack {
                Button("Setup instructions") { NSWorkspace.shared.open(LocalSpeechConfiguration.resource("LOCAL_SPEECH_SETUP.md")) }
                Button("Check paths") {
                    do { try LocalSpeechConfiguration.saved.validate(); status = "Paths found. Start Listen to load and verify the models; Python dependencies are checked then." }
                    catch { status = error.localizedDescription }
                }
            }
            if !status.isEmpty { Text(status).font(.caption).textSelection(.enabled) }
            Text("Community-1 is free, but Hugging Face requires an account and acceptance of its download conditions, including sharing contact information. Kura does not collect or store that token.").font(.caption).foregroundStyle(.secondary)
            Link("Review Community-1 model and access conditions", destination: URL(string: "https://huggingface.co/pyannote/speaker-diarization-community-1")!)
                .font(.caption)
        }
        .onChange(of: python) { _, _ in status = "" }
        .onChange(of: whisper) { _, _ in status = "" }
        .onChange(of: whisperModel) { _, _ in status = "" }
        .onChange(of: speakerModel) { _, _ in status = "" }
    }
    private func path(_ title: String, value: Binding<String>, directory: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Choose a local path…", text: value).textFieldStyle(.roundedBorder).accessibilityLabel(title)
                Button("Browse…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = directory; panel.canChooseFiles = !directory
                    panel.allowsMultipleSelection = false; panel.level = .statusBar
                    panel.title = title
                    if panel.runModal() == .OK, let url = panel.url { value.wrappedValue = url.path }
                }.accessibilityLabel("Browse for \(title)")
            }
        }
    }
}
