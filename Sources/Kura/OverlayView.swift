import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum KuraStyle {
    static let accent = Color(red: 0.30, green: 0.69, blue: 0.59)
    static let muted = Color.secondary
}

struct KuraChipButtonStyle: ButtonStyle {
    /// Tinted chips are for primary actions; secondary actions use neutral so
    /// the accent color keeps its meaning instead of painting every button.
    var tinted = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(tinted ? KuraStyle.accent.opacity(configuration.isPressed ? 0.3 : 0.14) : Color.primary.opacity(configuration.isPressed ? 0.14 : 0.06), in: Capsule())
            .overlay(Capsule().stroke(tinted ? KuraStyle.accent.opacity(0.3) : Color.primary.opacity(0.14), lineWidth: 1))
            .foregroundStyle(tinted ? KuraStyle.accent : .primary)
            .contentShape(Capsule())
    }
}

struct OverlayView: View {
    @ObservedObject var viewModel: OverlayViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showContext = false
    @State private var showCapture = false
    @State private var dropped = false
    @State private var editingLine: TranscriptLine?
    @State private var attachment: ContextAttachment?
    @FocusState private var inputFocused: Bool

    var body: some View {
        Group {
            if viewModel.viewMode == .icon { IconOverlayView(viewModel: viewModel) }
            else { workspace }
        }
        .modifier(KuraAppearance(chrome: viewModel.viewMode != .icon))
        .clipShape(RoundedRectangle(cornerRadius: viewModel.viewMode == .icon ? 0 : 18))
        .overlay {
            if viewModel.viewMode != .icon {
                RoundedRectangle(cornerRadius: 18).stroke(dropped ? KuraStyle.accent : Color.primary.opacity(0.12), lineWidth: dropped ? 3 : 1)
            }
        }
        .disabled(viewModel.transitioning)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropped, perform: acceptDrop)
        .sheet(isPresented: $showContext) { ContextView(viewModel: viewModel, onDone: { showContext = false }) }
        .sheet(isPresented: $showCapture) { CaptureSetupView(model: viewModel) }
        .sheet(item: $editingLine) { line in TranscriptEditor(line: line) { text, speaker, all in viewModel.correctLine(line, text: text, speaker: speaker, renameAll: all) } }
        .sheet(item: $attachment) { item in AttachmentPreview(item: item) }
        .onReceive(NotificationCenter.default.publisher(for: .kuraFocusInput)) { _ in inputFocused = true }
    }
    private var workspace: some View {
        HStack(spacing: 0) {
            if viewModel.sidebarOpen && !viewModel.compact { library.frame(width: 220); Divider() }
            VStack(spacing: 0) {
                header
                Divider()
                if viewModel.restoring { ProgressView("Opening your workspace…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else {
                    if !viewModel.compact { contextStrip; tabs }
                    if viewModel.tab == .wrapUp && !viewModel.compact {
                        WrapUpView(model: viewModel)
                    } else if viewModel.current.lines.isEmpty { welcome }
                    else {
                        ConversationView(lines: viewModel.current.lines, target: $viewModel.scrollTarget,
                                         onEdit: { editingLine = $0 }, onAsk: { viewModel.askMore($0) })
                    }
                    if !viewModel.compact && viewModel.tab != .wrapUp { assistBar }
                    if viewModel.tab != .wrapUp { WorkspaceAIControls().disabled(viewModel.status == .streaming) }
                    composer
                    feedback
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private var header: some View {
        HStack(spacing: 12) {
            if !viewModel.sidebarOpen || viewModel.compact { KuraLogo(size: 28); KuraVersionTag() }
            Button { viewModel.sidebarOpen.toggle() } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(.plain).help("Show meeting library").accessibilityLabel("Toggle meeting library")
            VStack(alignment: .leading, spacing: 3) {
                TextField("Name this meeting", text: Binding(get: { viewModel.current.meta.title }, set: { value in viewModel.editCurrent { $0.meta.title = value } }))
                    .textFieldStyle(.plain).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    .accessibilityLabel("Meeting title")
                HStack(spacing: 5) {
                    Circle().fill(viewModel.alwaysOnActive ? KuraStyle.accent : Color.secondary).frame(width: 6, height: 6)
                    Text(viewModel.selected != nil ? "Saved meeting · live session kept separately" : viewModel.captureStatus + (viewModel.ownVoiceActive ? " · mic on" : ""))
                    if let engine = viewModel.current.captureEngine {
                        Text("·").foregroundStyle(.tertiary)
                        Label(OverlayViewModel.engineLabel(engine), systemImage: engine == "realtime" ? "cloud" : "laptopcomputer")
                            .foregroundStyle(engine == "realtime" ? .orange : .secondary)
                            .help(engine == "realtime" ? "This meeting was captured via OpenAI Realtime — audio went to OpenAI and answers were billed to your API key." : "This meeting was captured on-device.")
                    }
                    if viewModel.alwaysOnActive {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(duration(until: context.date)).monospacedDigit()
                        }
                        ProgressView(value: viewModel.audioLevel).frame(width: 42).help("System audio activity")
                    }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if viewModel.selected != nil {
                Button("Back to live") { viewModel.backToLive() }.buttonStyle(KuraChipButtonStyle(tinted: false))
            } else {
                Button { viewModel.toggleAlwaysOn() } label: {
                    Label(viewModel.alwaysOnActive ? "Pause" : "Listen", systemImage: viewModel.alwaysOnActive ? "pause.fill" : "waveform")
                }.buttonStyle(.borderedProminent).controlSize(.small)
            }
            Menu {
                Button("Meeting capture…") { showCapture = true }
                if viewModel.viewMode != .full { Button("Expand workspace") { viewModel.setViewMode(.full) } }
                if viewModel.viewMode != .compact { Button("Compact view") { viewModel.setViewMode(.compact) } }
                Button("Icon view") { viewModel.setViewMode(.icon) }
                Button("Export this meeting…") { viewModel.exportMeeting() }
                Button("Settings…") { NotificationCenter.default.post(name: .kuraOpenSettings, object: nil) }
                Divider()
                Button("New meeting") { viewModel.startNewSession() }
                Button("Quit Kura") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .rotationEffect(.degrees(90))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }.padding(16)
    }
    private var contextStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { showContext = true } label: { Label("Add context", systemImage: "plus.circle") }
                    .buttonStyle(KuraChipButtonStyle(tinted: false))
                if !viewModel.current.context.isEmpty { Label("Notes included", systemImage: "note.text").font(.caption).foregroundStyle(.secondary) }
                ForEach(viewModel.current.attachments) { item in
                    HStack(spacing: 5) {
                        Button { attachment = item } label: { Label(item.name, systemImage: item.warning.isEmpty ? "doc.text" : "exclamationmark.triangle").lineLimit(1) }.buttonStyle(.plain)
                        Button { viewModel.editCurrent { $0.attachments.removeAll { $0.id == item.id } } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Remove \(item.name)")
                    }.font(.caption).padding(.horizontal, 9).padding(.vertical, 6).background(KuraStyle.accent.opacity(0.12), in: Capsule())
                }
                if viewModel.importing { ProgressView().controlSize(.small); Text("Reading files…").font(.caption) }
                if viewModel.current.contextIsTrimmed { Text("Context limit reached · review notes").font(.caption).foregroundStyle(.orange) }
                if viewModel.current.attachments.isEmpty && viewModel.current.context.isEmpty { Text("Drop PDFs or notes here").font(.caption).foregroundStyle(.tertiary) }
            }.padding(.horizontal, 16).padding(.vertical, 10)
        }
    }
    private var tabs: some View {
        HStack {
            Picker("Workspace", selection: $viewModel.tab) { ForEach(WorkspaceTab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 235)
            Spacer()
            if viewModel.selected == nil {
                if !viewModel.autoAnswerStatus.isEmpty {
                    Text(viewModel.autoAnswerStatus).font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Auto answer", isOn: $viewModel.autoQA).toggleStyle(.switch).controlSize(.mini).font(.caption)
                    .help("Answer detected questions after a short speech pause. Apple waits for stable words and quiet audio; local transcription depends on processing speed.")
            }
        }.padding(.horizontal, 16).padding(.bottom, 10)
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 15) {
            Spacer(minLength: 0)
            Image(systemName: "waveform.bubble.fill").font(.system(size: 34)).foregroundStyle(KuraStyle.accent)
            Text("A little preparation.\nA clearer conversation.").font(.system(size: viewModel.compact ? 20 : 26, weight: .semibold, design: .rounded))
            Text("Give Kura a goal, add your notes, and start listening. Your meeting saves as you go.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !viewModel.compact {
                TextField("What would make this meeting a success?", text: Binding(get: { viewModel.current.goal }, set: { value in viewModel.editCurrent { $0.goal = value } }))
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Meeting goal")
                HStack {
                    ForEach(["Planning", "Customer call", "Brainstorm"], id: \.self) { name in
                        Button(name) {
                            viewModel.editCurrent {
                                if $0.meta.title.isEmpty { $0.meta.title = name }
                                $0.goal = name == "Planning" ? "Agree on priorities, owners, and next steps." : name == "Customer call" ? "Understand needs, resolve questions, and agree on a next step." : "Explore possibilities and select ideas worth trying."
                            }
                        }
                    }
                }.buttonStyle(KuraChipButtonStyle())
                Button("Choose a meeting window…") { showCapture = true }.buttonStyle(.link)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: 490, alignment: .leading).padding(22).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var assistBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button("Catch me up") { viewModel.assist(.recap) }
                Button("Suggest a response") { viewModel.assist(.whatToSay) }
                Button("Capture decision") { viewModel.captureDecision() }
                Button("Wrap up", systemImage: "checkmark.circle") { viewModel.assist(.summarize) }
            }.buttonStyle(KuraChipButtonStyle()).disabled(viewModel.status == .streaming).padding(.horizontal, 16).padding(.vertical, 8)
        }
    }
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(viewModel.selected == nil ? "Ask about this conversation…" : "Ask this saved meeting…", text: $viewModel.question, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...5).focused($inputFocused)
                .onKeyPress(keys: [.return]) { press in
                    if press.modifiers.contains(.command) { viewModel.send(); return .handled }; return .ignored
                }
                .accessibilityLabel("Ask Kura")
            if viewModel.selected == nil {
                Button { if viewModel.status == .listening { viewModel.stopListening() } else { viewModel.startListening() } } label: {
                    Image(systemName: viewModel.status == .listening ? "mic.fill" : "mic")
                }.buttonStyle(.plain).foregroundStyle(viewModel.status == .listening ? Color.red : .secondary)
                    .disabled(viewModel.status == .streaming).help("Dictate a question · hold Right Option").accessibilityLabel("Toggle dictation")
            }
            if viewModel.status == .streaming {
                Button("Stop", systemImage: "stop.fill") { viewModel.stopAnswer() }.controlSize(.small)
            } else {
                Button { viewModel.send() } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderedProminent).disabled(!viewModel.canSend).help("Send · Command Return").accessibilityLabel("Send question")
            }
        }.padding(12).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 16)
    }
    private var feedback: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !viewModel.lastError.isEmpty {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(viewModel.lastError).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if viewModel.canRetry { Button("Retry") { viewModel.retry() }.disabled(viewModel.status == .streaming) }
                    Button { viewModel.lastError = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss error")
                }.font(.caption)
            }
            if !viewModel.notice.isEmpty {
                HStack { Text(viewModel.notice).lineLimit(2)
                    if viewModel.lastDeleted != nil { Button("Undo") { viewModel.undoDelete() }.buttonStyle(KuraChipButtonStyle(tinted: false)).controlSize(.small) }
                    else if viewModel.lastAutoBinding != nil { Button("Undo") { viewModel.undoAutoBinding() }.buttonStyle(KuraChipButtonStyle(tinted: false)).controlSize(.small) }
                    Spacer(); Button { viewModel.notice = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss notice") }.font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Label(viewModel.saveStatus, systemImage: viewModel.saveStatus == "Saved locally" ? "checkmark.shield" : "externaldrive")
                Spacer()
                if viewModel.status == .streaming { ProgressView().controlSize(.mini); Text(viewModel.progress.isEmpty ? "Kura is thinking…" : viewModel.progress) }
                else { Text(viewModel.current.aiSpendUSD > 0 ? "AI spend $\(ModelPricing.formatUSD(viewModel.current.aiSpendUSD)) · ⌘↩ send · ⌃⌥Space hide" : "⌘↩ send · ⌃⌥Space hide") }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }
    private var library: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) { KuraLogo(); Text("Kura").font(.system(size: 22, weight: .bold, design: .rounded)); KuraVersionTag().padding(.top, 6); Spacer() }
            Button { viewModel.startNewSession() } label: { Label("New meeting", systemImage: "plus").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
            TextField("Search meetings", text: $viewModel.search).textFieldStyle(.roundedBorder)
            Toggle("Favorites", isOn: $viewModel.favoriteOnly).toggleStyle(.checkbox).font(.caption)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    if viewModel.filteredMeetings.isEmpty { Text(viewModel.search.isEmpty ? "Your meetings will live here. Everything stays on this Mac." : "No matching meetings.").font(.caption).foregroundStyle(.secondary).padding(.top, 20) }
                    ForEach(viewModel.filteredMeetings) { meeting in
                        Button { viewModel.viewMeeting(meeting) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(meeting.title).font(.system(size: 12, weight: .medium)).lineLimit(2); if meeting.favorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.orange) } }
                                Text(meeting.meta.date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.system(size: 10)).foregroundStyle(.secondary)
                                if !meeting.tags.isEmpty { Text(meeting.tags).font(.caption2).foregroundStyle(KuraStyle.accent).lineLimit(1) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(viewModel.selected?.id == meeting.id ? KuraStyle.accent.opacity(0.16) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).contextMenu { Button("Move to Trash", role: .destructive) { viewModel.deleteMeeting(meeting) } }
                    }
                }
            }
            Button("Settings", systemImage: "gearshape") { NotificationCenter.default.post(name: .kuraOpenSettings, object: nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
        }.padding(16).background(Color.primary.opacity(0.025))
    }
    private func duration(until now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(viewModel.captureStartedAt)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !viewModel.importing else { return false }
        let urls = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        Task {
            var result: [URL] = []
            for provider in urls {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { value, _ in
                        if let data = value as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                        else { continuation.resume(returning: value as? URL) }
                    }
                }
                if let url { result.append(url) }
            }
            viewModel.importFiles(result)
        }
        return !urls.isEmpty
    }
}

private struct ConversationView: View {
    let lines: [TranscriptLine]
    @Binding var target: UUID?
    var onEdit: (TranscriptLine) -> Void
    var onAsk: (String) -> Void
    @State private var visibleCount = 150
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if lines.count > visibleCount { Button("Load earlier conversation") { visibleCount += 150 } }
                    ForEach(lines.suffix(visibleCount)) { line in
                        TranscriptRow(line: line, onEdit: { onEdit(line) }, onAsk: { onAsk(line.text) }).equatable().id(line.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(18)
            }
            // Messages-style following: stays pinned to the latest line as it
            // arrives or grows; scrolling up releases, scrolling back re-engages.
            .defaultScrollAnchor(.bottom)
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: target) {
                guard let id = target else { return }
                visibleCount = lines.count
                Task { @MainActor in await Task.yield(); proxy.scrollTo(id, anchor: .center); target = nil }
            }
        }
    }
}
private struct TranscriptRow: View, Equatable {
    let line: TranscriptLine
    var onEdit: () -> Void
    var onAsk: () -> Void
    @AppStorage("showAnswerCosts") private var showAnswerCosts = true
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.line == rhs.line }
    // Legacy sessions can hold pathological mega-lines (tens of KB from the
    // EOU-latching era); rendering them whole melts the SwiftUI graph.
    private var displayText: String {
        line.text.count > 4000 ? String(line.text.prefix(4000)) + "\n… (very long passage — Copy gets the full text)" : line.text
    }
    private var metaCaption: String? {
        guard showAnswerCosts, line.source == "assistant", line.isFinal, let meta = line.answerMeta else { return nil }
        var parts = [meta.model]
        if let input = meta.inputTokens, let output = meta.outputTokens {
            parts.append("\(ModelPricing.formatTokenCount(input)) in · \(ModelPricing.formatTokenCount(output)) out")
        }
        if let cost = meta.costUSD { parts.append("$\(ModelPricing.formatUSD(cost))") }
        if let first = meta.firstTokenSeconds { parts.append(String(format: "first token %.1fs", first)) }
        if let total = meta.totalSeconds { parts.append(String(format: "%.1fs", total)) }
        return parts.joined(separator: " · ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: line.source == "assistant" ? "sparkle" : line.source == "decision" ? "checkmark.seal" : "person.crop.circle")
                    .foregroundStyle(line.source == "assistant" ? KuraStyle.accent : .secondary)
                Button(line.speaker) { onEdit() }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).help("Edit text or correct the speaker")
                if line.suggestedName != nil { Text("Name suggested").font(.caption2).foregroundStyle(.orange) }
                if line.timestamp != .distantPast { Text(line.timestamp, format: .dateTime.hour().minute()).font(.system(size: 10)).foregroundStyle(.tertiary) }
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(line.text, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).help("Copy passage").accessibilityLabel("Copy passage")
            }
            if line.source == "assistant" {
                if line.isFinal { MarkdownText(text: displayText, fontSize: 14) }
                else { Text(displayText.isEmpty ? "Thinking…" : displayText).font(.system(size: 14)).foregroundStyle(.secondary) }
                if let caption = metaCaption { Text(caption).font(.caption2).foregroundStyle(.secondary) }
            } else { Text(displayText).font(.system(size: 14)).foregroundStyle(line.isFinal ? .primary : .secondary) }
        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            .padding(line.source == "assistant" ? 12 : 0)
            .background(line.source == "assistant" ? KuraStyle.accent.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .contextMenu { Button("Edit passage / speaker…", action: onEdit); Button("Ask Kura about this", action: onAsk) }
    }
}

struct WrapUpView: View {
    @ObservedObject var model: OverlayViewModel
    @State private var editing = false
    private var notes: Binding<String> {
        Binding(get: { model.current.wrapUp.notes }, set: { value in model.editCurrent { $0.wrapUp.notes = value } })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading) { Text("Make the next step easy.").font(.system(size: 21, weight: .semibold, design: .rounded)); Text("Review and edit before sharing.").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if !model.current.wrapUp.notes.isEmpty {
                            Button(editing ? "Done" : "Edit", systemImage: editing ? "checkmark" : "pencil") { editing.toggle() }
                                .buttonStyle(KuraChipButtonStyle(tinted: false))
                        }
                        Button("Export…", systemImage: "square.and.arrow.up") { model.exportMeeting() }
                            .buttonStyle(KuraChipButtonStyle(tinted: false))
                        Button("Generate", systemImage: "sparkles") { editing = false; model.generateWrapUp() }
                            .buttonStyle(KuraChipButtonStyle()).disabled(model.status == .streaming)
                    }
                    if model.wrapUpFraction >= 0 {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkles").foregroundStyle(KuraStyle.accent)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(model.progress.isEmpty ? "Writing your wrap-up…" : model.progress)
                                    .font(.caption).foregroundStyle(.secondary)
                                ProgressView(value: model.wrapUpFraction).tint(KuraStyle.accent)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(KuraStyle.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    }
                    // The wrap-up reads as one structured document, not a stack of
                    // form fields; Edit switches to the raw text for changes.
                    if editing || (model.current.wrapUp.notes.isEmpty && model.status != .streaming) {
                        WorkspaceSection("Wrap-up") {
                            TextEditor(text: notes)
                                .font(.system(size: 14)).scrollContentBackground(.hidden)
                                .frame(minHeight: 420).padding(6).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            MarkdownText(text: model.current.wrapUp.notes, fontSize: 14).textSelection(.enabled)
                            // A pulsing caret marks where new text will land while the
                            // wrap-up streams in.
                            if model.status == .streaming {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(KuraStyle.accent)
                                    .frame(width: 20, height: 3)
                                    .phaseAnimator([0.25, 1.0]) { view, phase in view.opacity(phase) } animation: { _ in .easeInOut(duration: 0.7) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(18)
            }
            // Pinned footer — outside the scroll area so it never gets clipped
            // behind a long document.
            HStack(spacing: 10) {
                Button { model.editCurrent { $0.favorite.toggle() } } label: {
                    Image(systemName: model.current.favorite ? "star.fill" : "star")
                        .font(.system(size: 14))
                        .foregroundStyle(model.current.favorite ? .orange : .secondary)
                        .frame(width: 30, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.current.favorite ? "Remove from favorites" : "Mark as favorite")
                HStack(spacing: 7) {
                    Image(systemName: "tag").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("Tags, separated by commas", text: Binding(get: { model.current.tags }, set: { value in model.editCurrent { $0.tags = value } }))
                        .textFieldStyle(.plain).font(.system(size: 12))
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.14), lineWidth: 1))
                .frame(maxWidth: 320)
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
        }
        .onAppear { model.seedWrapUpNotesIfNeeded() }
    }
}
private struct TranscriptEditor: View {
    let line: TranscriptLine
    var save: (String, String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var speaker = ""
    @State private var all = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Get the details right").font(.title2.bold())
            TextField("Speaker name", text: $speaker).textFieldStyle(.roundedBorder)
            if let suggestion = line.suggestedName { Button("Use suggested name: \(suggestion)") { speaker = suggestion }; Text("From a visible meeting-window cue. Confirm it matches this voice.").font(.caption).foregroundStyle(.secondary) }
            Toggle("Rename every “\(line.speaker)” passage in this meeting", isOn: $all).font(.caption)
            if line.speaker == "Unknown speaker" { Text("Unknown passages may contain different people. Only rename all if you are sure.").font(.caption).foregroundStyle(.orange) }
            TextEditor(text: $text).font(.body).frame(height: 170).border(Color.secondary.opacity(0.2))
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Save correction") { save(text, speaker, all); dismiss() }.buttonStyle(.borderedProminent).disabled(speaker.trimmingCharacters(in: .whitespaces).isEmpty) }
        }.padding(22).frame(width: 470).onAppear { text = line.text; speaker = line.speaker }
    }
}
extension Notification.Name {
    static let kuraFocusInput = Notification.Name("kuraFocusInput")
    static let kuraOpenSettings = Notification.Name("kuraOpenSettings")
}
