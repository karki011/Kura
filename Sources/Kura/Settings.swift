// Settings — UserDefaults for non-secret prefs, Keychain for API keys; SwiftUI settings view.
import SwiftUI
import AppKit

enum ProviderKind: String, CaseIterable, Identifiable {
    case anthropic = "Anthropic"
    case openAICompatible = "OpenAI-compatible"
    case ollama = "Ollama (local)"
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAICompatible: "Custom API (OpenAI-compatible)"
        case .ollama: "Ollama (local)"
        }
    }
}

struct SettingsStore: Sendable {
    static let shared = SettingsStore()

    static let anthropicModels = ["claude-opus-4-7", "claude-sonnet-4-5", "claude-haiku-4-5"]
    static let effortLevels = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    private var defaults: UserDefaults { .standard }

    var provider: ProviderKind {
        ProviderKind(rawValue: defaults.string(forKey: "provider") ?? "") ?? .anthropic
    }
    var anthropicModel: String {
        defaults.string(forKey: "anthropicModel").flatMap { $0.isEmpty ? nil : $0 } ?? "claude-sonnet-4-5"
    }
    var openAIBaseURL: String {
        defaults.string(forKey: "openAIBaseURL").flatMap { $0.isEmpty ? nil : $0 } ?? "https://api.openai.com/v1"
    }
    var openAIModel: String {
        defaults.string(forKey: "openAIModel").flatMap { $0.isEmpty ? nil : $0 } ?? "gpt-5-mini"
    }
    var ollamaBaseURL: String {
        defaults.string(forKey: "ollamaBaseURL").flatMap { $0.isEmpty ? nil : $0 } ?? "http://127.0.0.1:11434"
    }
    var ollamaModel: String {
        defaults.string(forKey: "ollamaModel").flatMap { $0.isEmpty ? nil : $0 } ?? "llama3.2"
    }
    var reasoningEffort: String {
        defaults.string(forKey: "reasoningEffort").flatMap { $0.isEmpty ? nil : $0 } ?? "none"
    }

    var activeModel: String {
        switch provider {
        case .anthropic: anthropicModel
        case .openAICompatible: openAIModel
        case .ollama: ollamaModel
        }
    }

    func makeProvider() -> any LLMProvider {
        switch provider {
        case .anthropic:
            return AnthropicProvider(apiKey: Keychain.get(account: "anthropic") ?? "", model: anthropicModel)
        case .openAICompatible:
            return OpenAICompatibleProvider(apiKey: Keychain.get(account: "openai") ?? "",
                                            baseURL: openAIBaseURL,
                                            model: openAIModel,
                                            effort: reasoningEffort)
        case .ollama:
            return OllamaProvider(baseURL: ollamaBaseURL, model: ollamaModel)
        }
    }
}

struct SettingsView: View {
    @AppStorage("provider") private var providerRaw: String = ProviderKind.anthropic.rawValue
    @AppStorage("anthropicModel") private var anthropicModel: String = "claude-sonnet-4-5"
    @AppStorage("openAIBaseURL") private var openAIBaseURL: String = "https://api.openai.com/v1"
    @AppStorage("openAIModel") private var openAIModel: String = "gpt-5-mini"
    @AppStorage("customProviderName") private var customProviderName: String = ""
    @AppStorage("ollamaBaseURL") private var ollamaBaseURL: String = "http://127.0.0.1:11434"
    @AppStorage("ollamaModel") private var ollamaModel: String = "llama3.2"
    @AppStorage("reasoningEffort") private var reasoningEffort: String = "none"
    @AppStorage("debugMode") private var debugMode = false
    @AppStorage("overlayOpacity") private var overlayOpacity = 0.92
    @AppStorage("themeMode") private var themeMode = "auto"

    @State private var anthropicKey: String = Keychain.get(account: "anthropic") ?? ""
    @State private var openAIKey: String = Keychain.get(account: "openai") ?? ""
    @State private var savedFlash = false
    @State private var ollamaModels: [String] = []
    @State private var ollamaStatus = ""

    private var provider: ProviderKind {
        ProviderKind(rawValue: providerRaw) ?? .anthropic
    }

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Provider", selection: $providerRaw) {
                    ForEach(ProviderKind.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .pointingHandCursor()
            }
            if provider == .anthropic {
                Section("Anthropic API key (stored in Keychain)") {
                    SecureField("Anthropic API key", text: $anthropicKey)
                    HStack {
                        Button("Save API key") { saveKeys() }
                            .pointingHandCursor()
                        if savedFlash { Text("Saved").foregroundStyle(.green).font(.caption) }
                    }
                }
            }
            if provider == .openAICompatible {
                Section("Custom provider API key (stored in Keychain)") {
                    SecureField("API key", text: $openAIKey)
                    HStack {
                        Button("Save API key") { saveKeys() }
                            .pointingHandCursor()
                        if savedFlash { Text("Saved").foregroundStyle(.green).font(.caption) }
                    }
                    Text("The key stays in your macOS Keychain and is sent only to the API base URL below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Models") {
                switch provider {
                case .anthropic:
                    Picker("Anthropic model", selection: $anthropicModel) {
                        ForEach(Self.withCurrent(SettingsStore.anthropicModels, current: anthropicModel), id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    .pointingHandCursor()
                case .openAICompatible:
                    TextField("Provider name (for your reference)", text: $customProviderName)
                    TextField("API base URL", text: $openAIBaseURL)
                    TextField("Model ID", text: $openAIModel)
                    Text("Enter the provider's URL before `/chat/completions` and the exact model ID from its documentation. Use this for any provider that supports the OpenAI Chat Completions API.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Reasoning effort", selection: $reasoningEffort) {
                        ForEach(SettingsStore.effortLevels, id: \.self) { Text($0).tag($0) }
                    }
                    .pointingHandCursor()
                    .help("Only used for GPT-5/o-series model IDs. Other providers receive a standard Chat Completions request.")
                case .ollama:
                    TextField("Ollama server", text: $ollamaBaseURL)
                    HStack {
                        Button("Refresh installed models") { refreshOllamaModels() }
                            .pointingHandCursor()
                        if !ollamaStatus.isEmpty {
                            Text(ollamaStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if ollamaModels.count == 1 {
                        LabeledContent("Detected model") {
                            Text(ollamaModel)
                                .textSelection(.enabled)
                        }
                    } else if ollamaModels.count > 1 {
                        Picker("Detected model", selection: $ollamaModel) {
                            ForEach(ollamaModels, id: \.self) { Text($0).tag($0) }
                        }
                        .pointingHandCursor()
                    } else {
                        TextField("Fallback model", text: $ollamaModel)
                    }
                    Text("Kura automatically uses an installed local model. Pull a model first if none are detected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Appearance") {
                Picker("Card theme", selection: $themeMode) {
                    Text("Auto").tag("auto")
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                }
                .pickerStyle(.segmented)
                .pointingHandCursor()
                .help("Auto samples what's behind the overlay and flips text color to stay readable")
                HStack {
                    Text("Overlay opacity")
                    Slider(value: $overlayOpacity, in: 0.35...1.0)
                        .pointingHandCursor()
                    Text("\(Int(overlayOpacity * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 36)
                }
                .help("Lower = more see-through, so the overlay blocks less of what's behind it")
            }
            Section("Debugging") {
                Toggle("Debug mode (visible to screenshots, diagnostics line)", isOn: $debugMode)
                    .pointingHandCursor()
                    .help("Takes effect on next launch. Lets you screenshot the overlay to triage issues.")
                Button("Restart App Now") { restartApp() }
                    .controlSize(.small)
                    .pointingHandCursor()
                    .help("Relaunches Kura with current settings applied")
            }
            Section("App") {
                Button("Quit Kura", role: .destructive) { NSApp.terminate(nil) }
                    .controlSize(.small)
                    .pointingHandCursor()
                    .help("Also available anywhere via ⌃⌥Q")
            }
            Section("Hotkeys") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("⌃⌥Space — show/hide overlay")
                    Text("⌃⌥Return — send question")
                    Text("Hold Right-⌥ — push-to-talk")
                    Text("⌃⌥M — toggle listening")
                    Text("⌃⌥L — always-on listening (system audio)")
                    Text("⌃⌥E — summarize meeting + save")
                    Text("⌃⌥Q — quit app")
                    Text("⌃⌥, — open settings")
                    Text("⎋ — hide overlay")
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            if provider == .ollama { refreshOllamaModels() }
        }
        .onChange(of: providerRaw) { _, _ in
            if provider == .ollama { refreshOllamaModels() }
        }
    }

    private func saveKeys() {
        Keychain.set(anthropicKey, account: "anthropic")
        Keychain.set(openAIKey, account: "openai")
        savedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { savedFlash = false }
    }

    private static func withCurrent(_ models: [String], current: String) -> [String] {
        models.contains(current) ? models : [current] + models
    }

    private func refreshOllamaModels() {
        let address = ollamaBaseURL
        ollamaStatus = "Checking Ollama…"
        Task {
            do {
                let models = try await OllamaProvider.installedModels(baseURL: address)
                ollamaModels = models
                if let fallback = models.first {
                    if !models.contains(ollamaModel) { ollamaModel = fallback }
                    ollamaStatus = models.count == 1
                        ? "Using \(ollamaModel)"
                        : "Using \(ollamaModel) by default"
                } else {
                    ollamaStatus = "No models installed yet"
                }
            } catch {
                ollamaStatus = error.localizedDescription
            }
        }
    }
}
