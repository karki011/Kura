import SwiftUI

struct ModelSetupView: View {
    let provider: ProviderKind
    let account: String
    var baseURL = ""
    var compact = false
    @Binding var model: String
    @Binding var effort: String
    @State private var models: [AvailableModel] = []
    @State private var search = ""
    @State private var status = ""
    @State private var loading = false
    @State private var showingModels = false
    @State private var showingEffort = false
    @State private var task: Task<Void, Never>?
    @AppStorage("answerTokenLimit") private var tokenLimit = 4096
    private var levels: [String] {
        if provider == .anthropic { return models.first { $0.id == model }?.efforts ?? [] }
        return ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { showingModels.toggle() } label: {
                    Label(model.isEmpty ? "Choose model" : model, systemImage: "chevron.down")
                        .lineLimit(1).truncationMode(.middle)
                }
                .accessibilityLabel("Choose model")
                .help("Choose a model · \(provider.displayName)")
                .popover(isPresented: $showingModels) {
                    modelChooser.padding(16).frame(width: 360).modifier(KuraAppearance())
                }
                Button { showingEffort.toggle() } label: {
                    Label(effort == "default" ? "Provider default" : effort.capitalized, systemImage: "brain")
                        .lineLimit(1)
                }
                .accessibilityLabel("Reasoning effort")
                .popover(isPresented: $showingEffort) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Reasoning effort").font(.headline)
                        ForEach(["default"] + levels, id: \.self) { level in
                            Button {
                                effort = level
                                showingEffort = false
                            } label: {
                                HStack {
                                    Text(level == "default" ? "Provider default" : level.capitalized)
                                    Spacer()
                                    if level == effort { Image(systemName: "checkmark").foregroundStyle(KuraStyle.accent) }
                                }.padding(7).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        Text(provider == .anthropic ? "Refresh models to load Claude’s supported effort levels." : "Support varies by model. Provider default is safest.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(16).frame(width: 260).modifier(KuraAppearance())
                }
            }.controlSize(compact ? .small : .regular)
            if !compact {
                Text("Choose a model above, or enter its ID in the model picker. Refresh the catalog using your saved key.").font(.caption).foregroundStyle(.secondary)
                Text(provider == .anthropic ? "Claude effort choices come from its model capabilities." : "The catalog may include non-text models. Choose a text-generation model. Effort support varies by model.").font(.caption).foregroundStyle(.secondary)
                Text("Higher reasoning effort can increase latency and API cost. Your own provider key pays for requests; Kura supplies no credits.").font(.caption).foregroundStyle(.secondary)
                Stepper("Output + reasoning budget: \(tokenLimit) tokens", value: $tokenLimit, in: 1024...65536, step: 1024).font(.callout)
                Text("A request cap, not a spending limit. High effort may need more room before it can produce an answer.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { reloadCatalog() }
        .onChange(of: showingModels) { _, open in if open { search = ""; reloadCatalog() } }
        .onChange(of: showingEffort) { _, open in if open { reloadCatalog() } }
        .onDisappear { task?.cancel(); loading = false }
        .onChange(of: model) { _, _ in effort = "default" }
        .onChange(of: baseURL) { _, _ in task?.cancel(); loading = false; models = []; status = "" }
    }
    private func reloadCatalog() {
        models = ModelCatalog.cached(provider)
        normalizeEffort()
    }
    private var modelChooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(provider.displayName) model").font(.headline)
            HStack {
                Button(loading ? "Loading models…" : "Refresh available models") { refresh() }.disabled(loading)
                if loading { Button("Cancel") { task?.cancel(); loading = false } }
            }
            Text("Uses your saved key to list models available to your account. No meeting content is sent.").font(.caption).foregroundStyle(.secondary)
            if !models.isEmpty {
                TextField("Search \(models.count) available models…", text: $search).accessibilityLabel("Search available models")
                if !search.isEmpty && !models.contains(where: { $0.id.localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search) }) {
                    Text("No matching models. Try another search or enter an ID below.").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(models.filter { search.isEmpty || $0.id.localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search) }) { item in
                            Button { model = item.id; effort = "default"; showingModels = false } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name).font(.callout)
                                        if item.name != item.id { Text(item.id).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    if model == item.id { Image(systemName: "checkmark").foregroundStyle(KuraStyle.accent) }
                                }.padding(7).contentShape(Rectangle())
                                    .background(model == item.id ? KuraStyle.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(height: 220)
            } else {
                Text("No models loaded yet. Refresh to list models available to your saved key, or enter an ID below.").font(.callout).foregroundStyle(.secondary)
            }
            TextField("Model ID (or enter one manually)", text: $model).accessibilityLabel("Model ID")
                .onSubmit { showingModels = false }
            Button("Done") { showingModels = false }.frame(maxWidth: .infinity, alignment: .trailing)
            if !status.isEmpty { Text(status).font(.caption).textSelection(.enabled) }
        }
    }
    private func normalizeEffort() { if effort != "default" && !levels.contains(effort) { effort = "default" } }
    private func refresh() {
        task?.cancel(); loading = true; status = ""
        task = Task { @MainActor in
            do {
                let fetched: [AvailableModel]
                if Config.preview {
                    fetched = provider == .anthropic ? [AvailableModel(id: "claude-preview", name: "Claude preview (simulated)", efforts: ["low", "medium", "high"], adaptiveThinking: true)] : [AvailableModel(id: "gpt-preview", name: "OpenAI preview (simulated)")]
                } else {
                    let target = account
                    let key = await Task.detached { Keychain.get(account: target, allowInteraction: true) ?? "" }.value
                    try Task.checkCancellation()
                    fetched = try await ModelCatalog.fetch(provider: provider, key: key, baseURL: baseURL)
                }
                try Task.checkCancellation()
                models = fetched; ModelCatalog.save(fetched, provider: provider); normalizeEffort()
                status = "\(fetched.count) models loaded\(Config.preview ? " (simulated)" : "")."
            } catch { if Task.isCancelled { return }; status = error.localizedDescription }
            loading = false
        }
    }
}
