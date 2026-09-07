// OverlayView — single rounded translucent card: header, chat/transcript area, assist row, input, footer hints.
import SwiftUI
import AppKit

struct OverlayView: View {
    @ObservedObject var viewModel: OverlayViewModel
    @ObservedObject private var perms = PermissionManager.shared
    @State private var transcriptLineCount = 0
    @FocusState private var inputFocused: Bool
    @AppStorage("overlayOpacity") private var overlayOpacity = 0.92
    @AppStorage("themeMode") private var themeMode = "auto"
    @AppStorage("openAIModel") private var customModel = "gpt-5-mini"
    @AppStorage("ollamaModel") private var ollamaModel = "llama3.2"
    @ObservedObject private var themeSampler = ThemeSampler.shared
    
    private var effectiveLight: Bool {
        switch themeMode {
        case "light": return true
        case "dark": return false
        default: return themeSampler.suggestsLight
        }
    }

    private var statusColor: Color {
        switch viewModel.status {
        case .listening: return .red
        case .streaming: return .green
        case .error: return .orange
        case .idle: return viewModel.alwaysOnActive ? .blue : .gray
        }
    }

    private var thinking: Bool {
        viewModel.status == .streaming || viewModel.qaActive
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            HStack(spacing: 10) {
                if viewModel.sidebarOpen {
                    MeetingSidebar(meetings: viewModel.meetings, onSelect: { viewModel.viewMeeting($0) }, onDelete: { viewModel.deleteMeeting($0) })
                    Divider()
                }
                VStack(spacing: 10) {
                    if let meta = viewModel.viewingMeeting {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                            Text(meta.title)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            Button("Back to live") { viewModel.backToLive() }
                                .controlSize(.mini)
                                .pointingHandCursor()
                        }
                        .foregroundStyle(.secondary)
                    }
                    TranscriptArea(
                        lines: viewModel.viewingMeeting != nil ? viewModel.historyLines : viewModel.transcript.lines,
                        autoQA: $viewModel.autoQA,
                        onAskMore: { viewModel.askMore($0) }
                    )
                    assistRow
                    input
                }
            }
            footer
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(overlayOpacity) // background only — text stays fully opaque
                .environment(\.colorScheme, effectiveLight ? .light : .dark)
        )
        .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
        .shadow(color: viewModel.status == .listening ? Color.red.opacity(0.4) : .clear, radius: 18)
        .preferredColorScheme(effectiveLight ? .light : .dark)
        .onReceive(viewModel.transcript.$lines) { transcriptLineCount = $0.count }
        .onAppear { inputFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .kuraFocusInput)) { _ in
            inputFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.8), radius: 3)
                .scaleEffect(thinking ? 1.5 : 1)
                .opacity(thinking ? 0.4 : 1)
                .animation(thinking ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default, value: thinking)
                .help("Status — gray idle · blue always-on · red mic listening · green answering · orange error · pulsing: AI thinking")

            Spacer()

            Button {
                viewModel.sidebarOpen.toggle()
            } label: {
                Image(systemName: "sidebar.leading")
                    .foregroundStyle(viewModel.sidebarOpen ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .pointingHandCursor()
            .help("Meeting history")

            Button {
                viewModel.toggleAlwaysOn()
            } label: {
                Image(systemName: viewModel.alwaysOnActive ? "waveform.circle.fill" : "waveform.circle")
                    .foregroundStyle(viewModel.alwaysOnActive ? Color.blue : .secondary)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .pointingHandCursor()
            .help("Always-on listening (⌃⌥L)")

            Menu {
                Button("Start New Session…") {
                    viewModel.startNewSession()
                    NotificationCenter.default.post(name: .kuraOpenContext, object: nil)
                }
                Button("Meeting Context…") {
                    NotificationCenter.default.post(name: .kuraOpenContext, object: nil)
                }
                Button("Export Meeting…") { exportAll() }
                Divider()
                Button("Settings…") {
                    NotificationCenter.default.post(name: .kuraOpenSettings, object: nil)
                }
                Divider()
                Button("Restart App") { restartApp() }
                Button("Quit Kura") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .pointingHandCursor()
            .help("More actions")
        }
    }

    @State private var settingsBump = 0

    private var assistRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
            assistButton("Assist", .whatToSay)
            assistButton("Recap", .recap)
            assistButton("To-dos", .todos)
            assistButton("Follow-ups", .followUps)
            assistButton("Summarize", .summarize)
            Spacer()
            modelSwitcher
        }
        }
    }

    private var modelSwitcher: some View {
        let store = SettingsStore.shared
        let models: [String]
        let modelPreferenceKey: String
        switch store.provider {
        case .anthropic:
            models = SettingsStore.anthropicModels
            modelPreferenceKey = "anthropicModel"
        case .openAICompatible:
            models = [customModel]
            modelPreferenceKey = "openAIModel"
        case .ollama:
            models = [ollamaModel]
            modelPreferenceKey = "ollamaModel"
        }
        return HStack(spacing: 6) {
            Menu {
                Text("Model").font(.caption).foregroundStyle(.secondary)
                if store.provider != .anthropic {
                    Text(store.provider == .ollama
                         ? "Choose a local model in Settings."
                         : "Configure this provider's model in Settings.")
                        .font(.caption)
                    Button("Open Settings") {
                        NotificationCenter.default.post(name: .kuraOpenSettings, object: nil)
                    }
                } else {
                    ForEach(models, id: \.self) { m in
                        Button {
                            UserDefaults.standard.set(m, forKey: modelPreferenceKey)
                            settingsBump &+= 1
                        } label: {
                            if m == store.activeModel { Label(m, systemImage: "checkmark") } else { Text(m) }
                        }
                    }
                }
            } label: {
                pillLabel(icon: "cpu", text: store.activeModel)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .pointingHandCursor()

            if store.provider == .openAICompatible {
                Menu {
                    Text("Reasoning effort").font(.caption).foregroundStyle(.secondary)
                    ForEach(SettingsStore.effortLevels, id: \.self) { e in
                        Button {
                            UserDefaults.standard.set(e, forKey: "reasoningEffort")
                            settingsBump &+= 1
                        } label: {
                            if e == store.reasoningEffort { Label(e, systemImage: "checkmark") } else { Text(e) }
                        }
                    }
                } label: {
                    pillLabel(icon: "bolt", text: store.reasoningEffort)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .pointingHandCursor()
            }
        }
        .id(settingsBump)
    }

    private func pillLabel(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
    }

    private func assistButton(_ title: String, _ action: AssistAction) -> some View {
        Button(title) { viewModel.assist(action) }
            .buttonStyle(.plain)
            .focusable(false)
            .font(.system(size: 11))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
            .pointingHandCursor()
    }

    private func exportAll() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "kura-export.md"
        panel.sharingType = Config.debug ? .readOnly : .none
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            try? viewModel.exportText().write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func inputHeight(for text: String) -> CGFloat {
        let width: CGFloat = 580 - 28 - 34 // card padding + editor/box insets, biased narrow
        let rect = (text + "\n") .boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        )
        return min(140, max(30, rect.height + 22))
    }

    private var input: some View {
        ZStack(alignment: .topLeading) {
            if viewModel.question.isEmpty {
                Text("Ask or hold Right-⌥ to talk…")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .padding(.horizontal, 11)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $viewModel.question)
                .font(.system(size: 14))
                .focused($inputFocused)
                .scrollContentBackground(.hidden)
                .frame(height: inputHeight(for: viewModel.question))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .onKeyPress(keys: [.return], phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    viewModel.send()
                    return .handled
                }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
    }

    private var debugLine: String {
        "DEBUG mic:\(perms.mic.rawValue) speech:\(perms.speech.rawValue) ax:\(perms.accessibility) sr:\(perms.screenRecording) aod:\(viewModel.alwaysOnActive) sb:\(viewModel.sidebarOpen) lines:\(transcriptLineCount) status:\(viewModel.status) err:\(viewModel.lastError)"
    }

    private var footer: some View {
        VStack(spacing: 4) {
            if !viewModel.notice.isEmpty {
                Text(viewModel.notice)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.green.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if Config.debug {
                Text(debugLine)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.yellow.opacity(0.85))
                    .lineLimit(2)
            }
            Text("⌃⌥Space show/hide · ⌘↩/⌃⌥↩ send · hold Right-⌥ talk · ⌃⌥L listen · ⌃⌥, settings · ⎋ hide")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary.opacity(0.6))
        }
    }
}

private struct TranscriptArea: View {
    let lines: [TranscriptLine]
    @Binding var autoQA: Bool
    var onAskMore: (String) -> Void

    private func labelColor(_ speaker: String) -> Color {
        switch speaker {
        case "You": return Color.accentColor.opacity(0.8)
        case "AI": return Color.green.opacity(0.8)
        default: return .secondary
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Toggle("Auto Q&A — answer questions as they're asked", isOn: $autoQA)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .controlSize(.mini)
                    .pointingHandCursor()
                Spacer()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(lines) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Text(line.speaker + ":")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(labelColor(line.speaker))
                                    .frame(width: 44, alignment: .leading)
                                Group {
                                    if line.speaker == "AI" {
                                        MarkdownText(text: line.text.isEmpty && !line.isFinal ? "thinking…" : line.text, fontSize: 12)
                                    } else {
                                        Text(line.text.isEmpty ? "…" : line.text)
                                            .font(.system(size: 12, design: .monospaced))
                                    }
                                }
                                .foregroundStyle(.primary.opacity(line.isFinal ? 0.9 : 0.55))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contextMenu {
                                    if !line.text.isEmpty {
                                        Button("Ask AI for more detail") { onAskMore(line.text) }
                                    }
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("tbottom")
                    }
                    .padding(.horizontal, 2)
                }
                .onChange(of: lines) {
                    withAnimation(.linear(duration: 0.05)) {
                        proxy.scrollTo("tbottom", anchor: .bottom)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}


private struct MeetingSidebar: View {
    @ObservedObject var meetings: MeetingStore
    var onSelect: (MeetingMeta) -> Void
    var onDelete: (MeetingMeta) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Meetings")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(meetings.meetings) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.title)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(2)
                            (Text(m.date, style: .date) + Text(" ") + Text(m.date, style: .time))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(m) }
                        .pointingHandCursor()
                        .contextMenu {
                            Button("Delete", role: .destructive) { onDelete(m) }
                        }
                    }
                    if meetings.meetings.isEmpty {
                        Text("No past meetings yet — they're saved automatically when you start a new session or summarize.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary.opacity(0.7))
                            .padding(.top, 8)
                    }
                }
            }
        }
        .frame(width: 190)
    }
}

extension Notification.Name {
    static let kuraFocusInput = Notification.Name("kuraFocusInput")
    static let kuraOpenSettings = Notification.Name("kuraOpenSettings")
}
