// OverlayViewModel — state + streaming send logic for the overlay card.
import Foundation
import AppKit

let systemPrompt = """
    You are a sharp technical assistant listening in on technical conversations. \
    Infer the kind of question yourself — coding, system design, or general — and answer accordingly. \
    For coding: answer concisely and precisely, code in fenced blocks with language tags. \
    For system design: structure as Requirements, Architecture, Tradeoffs, with short bullets. \
    For everything else: direct answers without filler. Skip pleasantries in all cases.
    """

enum OverlayStatus: Equatable {
    case idle, listening, streaming, error
}

struct ChatMessage: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
}

enum AssistAction {
    case whatToSay, recap, todos, followUps, summarize

    var title: String {
        switch self {
        case .whatToSay: return "What should I say?"
        case .recap: return "Recap"
        case .todos: return "To-dos"
        case .followUps: return "Follow-ups"
        case .summarize: return "Summarize"
        }
    }

    func prompt(context: String) -> String {
        let ctx = context.isEmpty ? "(no transcript yet)" : context
        let base = "Here is the conversation so far:\n\(ctx)\n\n"
        switch self {
        case .whatToSay:
            return base + "Based on this, what should I say next? Answer briefly."
        case .recap:
            return base + "Recap this as structured meeting notes: Summary, Key decisions, Open questions, Action items."
        case .todos:
            return base + """
                Extract everything actionable from this conversation. Format exactly as:
                ### To-do list
                - [ ] action item (owner: You/Them when clear, with any deadline mentioned)
                ### Open questions
                - [ ] question that still needs an answer or follow-up
                ### Next steps
                - [ ] what should happen after this meeting
                Keep each item short and concrete.
                """
        case .followUps:
            return base + "List 3 likely follow-up questions with a short answer for each."
        case .summarize:
            return base + """
                The meeting is over. Write the complete wrap-up:
                ### Overview
                2-3 sentences on what this meeting was about and its outcome.
                ### Topics discussed
                - bullet per topic, one line each
                ### Key decisions
                - bullets
                ### Action items
                - [ ] item (owner: You/Them, deadline if mentioned)
                ### Open questions
                - [ ] unresolved items needing follow-up
                ### Next steps
                - [ ] what happens next
                Be concise and concrete throughout.
                """
        }
    }
}

@MainActor
final class OverlayViewModel: ObservableObject {
    @Published var question: String = ""
    @Published var messages: [ChatMessage] = []
    @Published var status: OverlayStatus = .idle
    @Published var lastError: String = ""
    @Published var alwaysOnActive = false
    @Published var autoQA: Bool = UserDefaults.standard.bool(forKey: "autoQA") {
        didSet { UserDefaults.standard.set(autoQA, forKey: "autoQA") }
    }

    let speech = SpeechManager()
    let transcript = TranscriptStore()
    let meetings = MeetingStore()
    private let screenAudio = ScreenAudioManager()
    private var streamTask: Task<Void, Never>?
    private var qaTask: Task<Void, Never>?
    private var preListenBase = ""

    // Per-session context (user notes + attached docs). One-to-one with a meeting:
    // injected into every LLM call this session, wiped when the session ends.
    @Published var sessionContext = ""
    // History viewing mode: when set, the feed shows this saved meeting read-only.
    @Published var viewingMeeting: MeetingMeta?
    @Published var historyLines: [TranscriptLine] = []
    @Published var sidebarOpen = true {
        didSet { onSidebarResize?(sidebarOpen) }
    }
    var onSidebarResize: ((Bool) -> Void)?

    init() {
        speech.onPartialResult = { [weak self] text in
            guard let self, self.status == .listening else { return }
            // Append across push-to-talk sessions: releasing and re-holding Right-⌥
            // continues the same utterance instead of replacing it.
            self.question = self.preListenBase.isEmpty ? text : self.preListenBase + " " + text
        }
        speech.onError = { [weak self] reason in
            self?.status = .error
            self?.lastError = reason
        }
        screenAudio.onTranscript = { [weak self] text, isFinal in
            guard let self else { return }
            if isFinal {
                self.transcript.commitFinal(text, speaker: "Them")
            } else {
                self.transcript.updatePartial(text, speaker: "Them")
                self.partialThem(text)
            }
        }
        screenAudio.onError = { [weak self] reason in
            self?.lastError = reason
            self?.alwaysOnActive = false
        }
        transcript.onLineFinalized = { [weak self] line in
            self?.maybeAnswer(line)
        }
        if SettingsStore.shared.provider == .ollama {
            Task { [weak self] in await self?.selectInstalledOllamaModel() }
        }
    }

    func startListening() {
        guard status != .streaming else { return }
        lastError = ""
        preListenBase = question.trimmingCharacters(in: .whitespacesAndNewlines)
        status = .listening
        speech.start()
    }

    func stopListening() {
        speech.stop()
        if status == .listening { status = .idle }
        // Commit the dictated text to the transcript as "You".
        let dictated = question.trimmingCharacters(in: .whitespacesAndNewlines)
        var finalText = dictated
        if !preListenBase.isEmpty, dictated.hasPrefix(preListenBase) {
            finalText = String(dictated.dropFirst(preListenBase.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !finalText.isEmpty, finalText != preListenBase {
            transcript.appendFinal(finalText, speaker: "You")
        }
    }

    func toggleAlwaysOn() {
        if alwaysOnActive {
            screenAudio.stop()
            alwaysOnActive = false
            return
        }
        // Process tap needs no Screen Recording permission — start directly.
        lastError = ""
        alwaysOnActive = true
        screenAudio.start()
    }

    func send() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        question = ""
        sendPrompt(q)
    }

    func assist(_ action: AssistAction) {
        if action == .summarize { pendingAutoExport = true }
        let maxChars = action == .summarize ? 8000 : 4000
        sendPrompt(action.prompt(context: transcript.recentContext(maxChars: maxChars)), display: action.title)
    }

    // MARK: Meeting export

    @Published var notice = ""
    private var pendingAutoExport = false

    func exportText() -> String {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
        var out = "# Kura Meeting — \(stamp)\n\n"
        for line in transcript.lines where !line.text.isEmpty {
            out += "**\(line.speaker):** \(line.text)\n\n"
        }
        return out
    }

    private func autoExportIfNeeded() {
        guard pendingAutoExport else { return }
        pendingAutoExport = false
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmm"
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Kura")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("meeting-\(fmt.string(from: Date())).md")
        do {
            try exportText().write(to: url, atomically: true, encoding: .utf8)
            notice = "Meeting saved → \(url.path)"
        } catch {
            notice = "Save failed: \(error.localizedDescription)"
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            self?.notice = ""
        }
    }

    // MARK: Auto Q&A — answer "Them" questions inline in the transcript.

    @Published private(set) var qaActive = false
    private var qaDebounce: Task<Void, Never>?
    private var answeredQuestionKeys: [String] = []
    private var pendingQuestionKey = ""

    // Fires on FINALIZED lines (safety net).
    private func maybeAnswer(_ line: TranscriptLine) {
        guard autoQA, line.speaker == "Them" else { return }
        scheduleAnswer(line.text)
    }

    // Fires on live PARTIAL lines: once a question-like partial is stable for
    // 2.5s, answer it — no waiting for the recognizer's commit window.
    func partialThem(_ text: String) {
        scheduleAnswer(text)
    }

    private func scheduleAnswer(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = questionKey(for: t)
        guard looksLikeQuestion(t),
              !answeredQuestionKeys.contains(where: { sameQuestion($0, key) }) else { return }
        qaDebounce?.cancel()
        pendingQuestionKey = key
        qaDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, let self, self.pendingQuestionKey == key else { return }
            self.pendingQuestionKey = ""
            self.answerQuestion(t, questionKey: key)
        }
    }

    private func answerQuestion(_ question: String, questionKey: String) {
        // Talking while we wait: newest question wins — cancel any in-flight answer.
        qaTask?.cancel()
        answeredQuestionKeys.append(questionKey)
        lastError = ""
        let context = transcript.recentContext(maxChars: 3000)
        let lineID = transcript.beginStreaming(speaker: "AI")
        let sys = """
            You are whispering answers to the user during a live conversation. \
            Answer the question directly and concisely, using the conversation context. \
            For coding questions give the key code; for design questions the key points. No pleasantries.
            """
        let msgs = [LLMMessage(role: "user", content: "\(contextPreamble.isEmpty ? "" : contextPreamble + "\n\n")Conversation so far:\n\(context)\n\nAnswer this question: \(question)")]
        qaActive = true
        qaTask = Task { [weak self] in
            defer {
                self?.qaTask = nil
                self?.qaActive = false
            }
            do {
                let provider = SettingsStore.shared.makeProvider()
                for try await delta in provider.stream(messages: msgs, system: sys) {
                    guard !Task.isCancelled else { return }
                    self?.transcript.appendDelta(delta, to: lineID)
                }
                self?.transcript.finalize(id: lineID)
            } catch is CancellationError {
                self?.transcript.finalize(id: lineID)
            } catch {
                self?.transcript.finalize(id: lineID, fallback: "⚠︎ \(error.localizedDescription)")
                self?.lastError = error.localizedDescription
            }
        }
    }

    private func questionKey(for text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func sameQuestion(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        let shorter = lhs.count <= rhs.count ? lhs : rhs
        let longer = lhs.count <= rhs.count ? rhs : lhs
        let wordCount = shorter.split(separator: " ").count
        return wordCount >= 3
            && longer.hasPrefix(shorter)
            && Double(shorter.count) / Double(longer.count) >= 0.6
    }

    private func looksLikeQuestion(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard t.count > 12 else { return false }
        if t.hasSuffix("?") { return true }
        let starters = ["what ", "how ", "why ", "when ", "where ", "which ", "who ",
                        "can you", "could you", "tell me", "explain", "describe", "design",
                        "implement", "walk me", "difference between", "write ", "give me"]
        return starters.contains { t.hasPrefix($0) }
    }

    private func sendPrompt(_ q: String, display: String? = nil) {
        guard status != .streaming else { return }
        streamTask?.cancel()
        lastError = ""
        messages.append(ChatMessage(role: .user, text: q))
        messages.append(ChatMessage(role: .assistant, text: ""))
        // Single unified feed: typed questions and streamed answers appear as transcript lines.
        // Assist buttons show their short label, not the full context-laden prompt.
        transcript.appendFinal(display ?? q, speaker: "You")
        let lineID = transcript.beginStreaming(speaker: "AI")
        status = .streaming
        let system = systemPrompt + contextPreamble
        // Full conversation so follow-ups ("explain that further") work like a real chat.
        // Excludes the empty assistant placeholder we just appended; capped to last 20.
        let history = messages.dropLast().suffix(20).map {
            LLMMessage(role: $0.role == .user ? "user" : "assistant", content: $0.text)
        }
        streamTask = Task { [weak self] in
            do {
                let provider = SettingsStore.shared.makeProvider()
                for try await delta in provider.stream(messages: history, system: system) {
                    guard !Task.isCancelled else { return }
                    self?.appendToLast(delta)
                    self?.transcript.appendDelta(delta, to: lineID)
                }
                self?.transcript.finalize(id: lineID)
                if !Task.isCancelled {
                    self?.status = .idle
                    self?.autoExportIfNeeded()
                }
            } catch is CancellationError {
                self?.transcript.finalize(id: lineID)
            } catch {
                self?.status = .error
                self?.lastError = error.localizedDescription
                self?.appendToLast("⚠︎ \(error.localizedDescription)")
                self?.transcript.finalize(id: lineID, fallback: "⚠︎ \(error.localizedDescription)")
            }
        }
    }

    // Right-click "Ask AI for more detail" on any feed line.
    func askMore(_ text: String) {
        sendPrompt("Go deeper on this — specifics, code, or examples:\n\n\(text)")
    }

    func clearChat() {
        streamTask?.cancel()
        qaTask?.cancel()
        qaDebounce?.cancel()
        messages = []
        transcript.clear()
        answeredQuestionKeys = []
        pendingQuestionKey = ""
        if status == .streaming { status = .idle }
    }

    // Meeting boundary: save the current session to history, wipe, reset context.
    func startNewSession() {
        _ = meetings.save(lines: transcript.lines, context: sessionContext)
        clearChat()
        sessionContext = ""
        viewingMeeting = nil
        historyLines = []
        notice = "New session started"
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.notice = ""
        }
    }

    func viewMeeting(_ meta: MeetingMeta) {
        guard let meeting = meetings.load(meta) else { return }
        historyLines = meeting.lines.map {
            TranscriptLine(speaker: $0.speaker, text: $0.text, isFinal: $0.isFinal)
        }
        viewingMeeting = meta
    }

    func backToLive() {
        viewingMeeting = nil
        historyLines = []
    }

    // Deleting from the sidebar: if that meeting is on screen, leave history mode.
    func deleteMeeting(_ meta: MeetingMeta) {
        meetings.delete(meta)
        if viewingMeeting == meta { backToLive() }
    }

    // Session-context preamble shared by every LLM call.
    private var contextPreamble: String {
        sessionContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : "\n\nBackground context for this conversation (provided by the user — use it, don't repeat it):\n" + sessionContext
    }

    private func appendToLast(_ delta: String) {
        guard !messages.isEmpty else { return }
        messages[messages.count - 1].text += delta
    }

    private func selectInstalledOllamaModel() async {
        let store = SettingsStore.shared
        do {
            let models = try await OllamaProvider.installedModels(baseURL: store.ollamaBaseURL)
            guard let fallback = models.first else { return }
            let selected = models.contains(store.ollamaModel) ? store.ollamaModel : fallback
            if selected != store.ollamaModel {
                UserDefaults.standard.set(selected, forKey: "ollamaModel")
                notice = "Using local model: \(selected)"
            }
        } catch {
            // Sending a prompt will show the actionable connection error; don't show a
            // launch-time error merely because Ollama is not running yet.
        }
    }
}
