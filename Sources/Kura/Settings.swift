// Settings — UserDefaults for non-secret prefs, Keychain for API keys; SwiftUI settings view.
import SwiftUI
import AppKit

enum ProviderKind: String, CaseIterable, Identifiable {
    case anthropic = "Anthropic"
    case openAI = "OpenAI"
    case openAICompatible = "OpenAI-compatible"
    case ollama = "Ollama (local)"
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .openAICompatible: "Custom API (OpenAI-compatible)"
        case .ollama: "Ollama (local)"
        }
    }
}

struct SettingsStore: Sendable {
    static let shared = SettingsStore()

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
        case .openAI: defaults.string(forKey: "directOpenAIModel") ?? "gpt-5-mini"
        case .openAICompatible: openAIModel
        case .ollama: ollamaModel
        }
    }

    func makeProvider() -> any LLMProvider {
        switch provider {
        case .anthropic:
            let model = anthropicModel, effort = defaults.string(forKey: "anthropicEffort") ?? "default"
            let adaptive = ModelCatalog.cached(.anthropic).first { $0.id == model }?.adaptiveThinking ?? false
            let limit = answerTokenLimit
            return KeychainBackedProvider(account: "anthropic") { key in
                AnthropicProvider(apiKey: key, model: model, effort: effort, adaptiveThinking: adaptive, tokenLimit: limit)
            }
        case .openAI:
            let model = activeModel, effort = defaults.string(forKey: "directOpenAIEffort") ?? "default", limit = answerTokenLimit
            let fast = defaults.object(forKey: "openAIFastMode") as? Bool ?? true
            return KeychainBackedProvider(account: "openai-direct") { key in
                OpenAIResponsesProvider(apiKey: key, model: model, effort: effort, tokenLimit: limit, fastMode: fast)
            }
        case .openAICompatible:
            let base = openAIBaseURL, model = openAIModel, effort = reasoningEffort
            return KeychainBackedProvider(account: "openai") { key in
                OpenAICompatibleProvider(apiKey: key, baseURL: base, model: model, effort: effort)
            }
        case .ollama:
            return OllamaProvider(baseURL: ollamaBaseURL, model: ollamaModel)
        }
    }
    var answerTokenLimit: Int {
        let value = defaults.integer(forKey: "answerTokenLimit")
        return value == 0 ? 4096 : min(65536, max(1024, value))
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
    @AppStorage("anthropicEffort") private var anthropicEffort = "default"
    @AppStorage("directOpenAIEffort") private var directOpenAIEffort = "default"
    @AppStorage("directOpenAIModel") private var directOpenAIModel = "gpt-5-mini"
    @AppStorage("debugMode") private var debugMode = false
    @AppStorage("overlayOpacity") private var overlayOpacity = 0.92
    @AppStorage("themeMode") private var themeMode = "auto"

    @AppStorage("settingsTab") private var settingsTab = "AI setup"
    @State private var connectionStatus = ""
    @State private var testing = false
    @State private var connectionTask: Task<Void, Never>?
    @State private var ollamaModels: [String] = []
    @State private var ollamaStatus = ""
    @AppStorage("transcriptionBackend") private var transcriptionBackend = "apple"
    @AppStorage("systemAudioCaptureDriver") private var captureDriver = "direct"

    private var provider: ProviderKind {
        ProviderKind(rawValue: providerRaw) ?? .anthropic
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    KuraLogo()
                    Text("Make Kura yours").font(.system(size: 22, weight: .bold, design: .rounded))
                    Spacer()
                    Image(systemName: "sparkle").foregroundStyle(KuraStyle.accent).font(.title2)
                }
                Text("Connect your AI, choose how to listen, and settle in.").foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                ForEach(["AI setup", "Audio", "Permissions", "Appearance", "Shortcuts"], id: \.self) { category in
                    Button { settingsTab = category } label: {
                        Text(category).font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .foregroundStyle(settingsTab == category ? KuraStyle.accent : .secondary)
                            .background(settingsTab == category ? KuraStyle.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(settingsTab == category ? .isSelected : [])
                }
            }.padding(4).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .contain).accessibilityLabel("Settings category")
            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            if settingsTab == "Permissions" { PermissionStatusView() }
            if settingsTab == "Audio" {
            CaptureDiagnosticsView()
            WorkspaceSection("Meeting transcription") {
                Picker("Audio capture", selection: $captureDriver) {
                    Text("Core Audio · direct callback").tag("direct")
                    Text("Cloak compatibility · original capture").tag("cloak")
                }
                Text("For troubleshooting missing audio. Pause Listen before switching; the next Listen uses the selected capture method. Neither method changes your AI provider or requires a paid speech service.").font(.caption).foregroundStyle(.secondary)
                Picker("Transcription", selection: $transcriptionBackend) {
                    Text("Apple · live text, no speaker separation").tag("apple")
                    Text("Local · Whisper + pyannote").tag("local")
                }
                Text("Both options have no paid speech API requirement. Changes apply the next time you start Listen. Apple may use its servers when on-device recognition is unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Listen shows the transcript. Auto answer responds to detected questions after a short pause. Apple uses about 1.2 seconds of stable text and 0.9 seconds of quiet audio before sending; your AI provider adds its response time. Local transcription also needs chunk processing time. You can type a question anytime.").font(.caption).foregroundStyle(.secondary)
            }
            if transcriptionBackend == "local" {
                LocalSpeechSetupView()
                Text("Local text and speaker labels appear every ~10 seconds plus processing time. Names are tentative; returning speakers may need relabeling after a long pause. Audio windows are stored temporarily on this Mac and deleted after processing.").font(.caption).foregroundStyle(.secondary)
            }
            }
            if settingsTab == "AI setup" {
            WorkspaceSection("Answer provider") {
                Picker("Provider", selection: $providerRaw) {
                    ForEach(ProviderKind.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .pointingHandCursor()
            }
            if provider == .anthropic {
                APIKeyEditor(account: "anthropic", title: "Anthropic API key", onCredentialChange: cancelConnectionTest)
            }
            if provider == .openAI {
                APIKeyEditor(account: "openai-direct", title: "OpenAI API key", onCredentialChange: cancelConnectionTest)
                Text("Uses OpenAI’s Responses API. Your ChatGPT subscription does not supply an API key or API credits.").font(.caption).foregroundStyle(.secondary)
            }
            if provider == .openAICompatible {
                APIKeyEditor(account: "openai", title: "Custom provider API key", onCredentialChange: cancelConnectionTest)
                    Text("The key stays in your macOS Keychain and is sent only to the API base URL below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
            }
            WorkspaceSection("Model & connection") {
                switch provider {
                case .anthropic:
                    ModelSetupView(provider: .anthropic, account: "anthropic", model: $anthropicModel, effort: $anthropicEffort).id("anthropic")
                case .openAI:
                    ModelSetupView(provider: .openAI, account: "openai-direct", model: $directOpenAIModel, effort: $directOpenAIEffort).id("openai")
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
                HStack {
                    Button(testing ? "Testing…" : "Test connection") { testConnection() }.disabled(testing)
                    if testing { Button("Cancel") { cancelConnectionTest() } }
                }
                Text(provider == .ollama ? "Sends a short test prompt to your configured Ollama server. No API key is required." : "Uses your saved key and sends only a short test prompt. Your provider may charge for this request.").font(.caption).foregroundStyle(.secondary)
                if !connectionStatus.isEmpty { Text(connectionStatus).font(.callout).textSelection(.enabled) }
            }
            }
            if settingsTab == "Appearance" {
            WorkspaceSection("Appearance") {
                Picker("Card theme", selection: $themeMode) {
                    Text("Auto").tag("auto")
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                }
                .pickerStyle(.segmented)
                .pointingHandCursor()
                .help("Auto follows your Mac’s appearance")
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
            WorkspaceSection("Debugging") {
                Toggle("Debug mode (visible to screenshots, diagnostics line)", isOn: $debugMode)
                    .pointingHandCursor()
                    .help("Takes effect on next launch. Lets you screenshot the overlay to triage issues.")
                Button("Restart App Now") { restartApp() }
                    .controlSize(.small)
                    .pointingHandCursor()
                    .help("Relaunches Kura with current settings applied")
            }
            WorkspaceSection("App") {
                Button("Quit Kura", role: .destructive) { NSApp.terminate(nil) }
                    .controlSize(.small)
                    .pointingHandCursor()
                    .help("Also available anywhere via ⌃⌥Q")
            }
            }
            if settingsTab == "Shortcuts" {
            WorkspaceSection("Keyboard shortcuts") {
                VStack(alignment: .leading, spacing: 10) {
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
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)
            }
            Text("Global shortcuts require Accessibility access. All meeting actions are also available as buttons.").font(.caption).foregroundStyle(.secondary)
            }
            }.frame(maxWidth: .infinity, alignment: .leading).textFieldStyle(.roundedBorder)
            }
            Divider()
            Label("Preferences save automatically. API keys save only when you choose Save key.", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(KuraAppearance())
        .onAppear {
            if provider == .ollama { refreshOllamaModels() }
        }
        .onChange(of: providerRaw) { _, _ in
            cancelConnectionTest()
            if provider == .ollama { refreshOllamaModels() }
        }
        .onDisappear { cancelConnectionTest() }
        .onChange(of: anthropicModel) { _, _ in cancelConnectionTest() }
        .onChange(of: openAIBaseURL) { _, _ in cancelConnectionTest() }
        .onChange(of: openAIModel) { _, _ in cancelConnectionTest() }
        .onChange(of: ollamaBaseURL) { _, _ in cancelConnectionTest() }
        .onChange(of: ollamaModel) { _, _ in cancelConnectionTest() }
        .onChange(of: reasoningEffort) { _, _ in cancelConnectionTest() }
        .onChange(of: anthropicEffort) { _, _ in cancelConnectionTest() }
        .onChange(of: directOpenAIEffort) { _, _ in cancelConnectionTest() }
        .onChange(of: directOpenAIModel) { _, _ in cancelConnectionTest() }
    }

    private func cancelConnectionTest() {
        connectionTask?.cancel()
        connectionTask = nil
        testing = false
        connectionStatus = ""
    }

    private func testConnection() {
        testing = true
        connectionStatus = ""
        let configuredProvider = SettingsStore.shared.makeProvider()
        connectionTask = Task { @MainActor in
            do {
                if Config.preview {
                    try await Task.sleep(for: .milliseconds(500))
                    connectionStatus = "Preview connection successful (simulated; no request sent)."
                } else {
                    var received = false
                    for try await token in configuredProvider.stream(messages: [LLMMessage(role: "user", content: "Reply with OK.")], system: "This is a connection test. Reply briefly.") {
                        try Task.checkCancellation()
                        if !token.isEmpty { received = true; break }
                    }
                    try Task.checkCancellation()
                    connectionStatus = received ? "Connected — your model responded." : "No response received. Check the model ID and endpoint."
                }
            } catch {
                if Task.isCancelled { return }
                connectionStatus = "Connection failed. Check your saved key, endpoint, and model. \(error.localizedDescription)"
            }
            testing = false
        }
    }

    private static func withCurrent(_ models: [String], current: String) -> [String] {
        models.contains(current) ? models : [current] + models
    }

    private func refreshOllamaModels() {
        if Config.preview {
            ollamaModels = ["preview-local-model"]
            ollamaModel = "preview-local-model"
            ollamaStatus = "Preview model detected (simulated)"
            return
        }
        let address = ollamaBaseURL
        ollamaStatus = "Checking Ollama…"
        Task {
            do {
                let models = try await OllamaProvider.installedModels(baseURL: address)
                guard address == ollamaBaseURL, provider == .ollama else { return }
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
                guard address == ollamaBaseURL, provider == .ollama else { return }
                ollamaStatus = error.localizedDescription
            }
        }
    }
}
