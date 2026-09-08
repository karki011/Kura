import SwiftUI
import AppKit

struct KuraLogo: View {
    var size: CGFloat = 32
    private static let icon: NSImage? = {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Kura.icns")
        return NSImage(contentsOf: Bundle.main.url(forResource: "Kura", withExtension: "icns") ?? source)
    }()
    var body: some View {
        Group {
            if let icon = Self.icon { Image(nsImage: icon).resizable().scaledToFit() }
            else { Image(systemName: "waveform.bubble.fill").resizable().scaledToFit().foregroundStyle(KuraStyle.accent) }
        }.frame(width: size, height: size).accessibilityLabel("Kura logo")
    }
}

struct WorkspaceAIControls: View {
    @AppStorage("provider") private var providerRaw = ProviderKind.anthropic.rawValue
    @AppStorage("anthropicModel") private var claudeModel = "claude-sonnet-4-5"
    @AppStorage("anthropicEffort") private var claudeEffort = "default"
    @AppStorage("directOpenAIModel") private var openAIModel = "gpt-5-mini"
    @AppStorage("directOpenAIEffort") private var openAIEffort = "low"
    @AppStorage("openAIModel") private var customModel = "gpt-5-mini"
    @AppStorage("reasoningEffort") private var customEffort = "none"
    @AppStorage("ollamaModel") private var localModel = "llama3.2"
    var body: some View {
        HStack(spacing: 8) {
            Text("Answer with").font(.caption).foregroundStyle(.secondary)
            switch ProviderKind(rawValue: providerRaw) ?? .anthropic {
            case .anthropic:
                ModelSetupView(provider: .anthropic, account: "anthropic", compact: true, model: $claudeModel, effort: $claudeEffort).id("claude")
            case .openAI:
                ModelSetupView(provider: .openAI, account: "openai-direct", compact: true, model: $openAIModel, effort: $openAIEffort).id("openai")
            case .openAICompatible:
                TextField("Model ID", text: $customModel).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                Picker("Effort", selection: $customEffort) {
                    ForEach(SettingsStore.effortLevels, id: \.self) { Text($0.capitalized).tag($0) }
                }.fixedSize()
            case .ollama:
                TextField("Local model", text: $localModel).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                Text("Local").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.help("Changes apply to your next answer. Provider and API keys are managed in Settings.")
            .padding(.horizontal, 16).padding(.vertical, 6)
    }
}
