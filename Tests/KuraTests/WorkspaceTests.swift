import Foundation

private func temporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("KuraTests-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private final class RecordingProvider: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [LLMMessage] = []
    private var calls = 0
    var callCount: Int { lock.withLock { calls } }
    var responseDelay: Duration?
    var response = "A useful answer."
    var suspended = false
    var failing = false
    var messages: [LLMMessage] { lock.withLock { recorded } }
    func stream(messages: [LLMMessage], system: String) -> AsyncThrowingStream<String, Error> {
        lock.withLock { recorded = messages; calls += 1 }
        let delay = responseDelay; let reply = response
        return AsyncThrowingStream { continuation in
            if failing { continuation.finish(throwing: KuraError.message("Simulated provider failure")) }
            else if let delay {
                let task = Task {
                    do { try await Task.sleep(for: delay); continuation.yield(reply); continuation.finish() }
                    catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { @Sendable _ in task.cancel() }
            }
            else if !suspended { continuation.yield(response); continuation.finish() }
        }
    }
}

@main
@MainActor
struct WorkspaceTests {
    static func main() async throws {
        let suite = WorkspaceTests()
        var failures = 0
        let checks: [(String, @MainActor () async throws -> Void)] = [
            ("captureDiagnosticsTrackStagesWithoutTranscript", { try suite.captureDiagnosticsTrackStagesWithoutTranscript() }),
            ("audioContinuesAcrossRecognitionRestarts", { try suite.audioContinuesAcrossRecognitionRestarts() }),
            ("oldMeetingMigration", { try suite.oldMeetingMigration() }),
            ("fullTranscriptSurvivesAndContextIncludesOversizedTail", { try suite.fullTranscriptSurvivesAndContextIncludesOversizedTail() }),
            ("repositoryDraftAndTrashRecovery", { try await suite.repositoryDraftAndTrashRecovery() }),
            ("localSpeechProtocolAndWAV", { try suite.localSpeechProtocolAndWAV() }),
            ("finalizedTranscriptTriggersQA", { try await suite.finalizedTranscriptTriggersQA() }),
            ("shortPauseRequiresStableTextAndLiveQuietAudio", { try suite.shortPauseRequiresStableTextAndLiveQuietAudio() }),
            ("conversationalTurnAnswersOnceAndAllowsFollowUp", { try await suite.conversationalTurnAnswersOnceAndAllowsFollowUp() }),
            ("busyAutoAnswerKeepsLatestQuestion", { try await suite.busyAutoAnswerKeepsLatestQuestion() }),
            ("newerQuestionInterruptsStaleAutoAnswer", { try await suite.newerQuestionInterruptsStaleAutoAnswer() }),
            ("pendingAutoAnswerCancelsWhenDisabledOrPaused", { try await suite.pendingAutoAnswerCancelsWhenDisabledOrPaused() }),
            ("spokenQuestionDetection", { try suite.spokenQuestionDetection() }),
            ("spokenQuestionLLMFallback", { try await suite.spokenQuestionLLMFallback() }),
            ("localWorkerDrainsFinalAudioIntoQA", { try await suite.localWorkerDrainsFinalAudioIntoQA() }),
            ("providerCatalogAndReasoningPayloads", { try suite.providerCatalogAndReasoningPayloads() }),
            ("speakerCuesDoNotGuessFromParticipantLists", { try suite.speakerCuesDoNotGuessFromParticipantLists() }),
            ("structuredWrapUpIncludesSource", { try suite.structuredWrapUpIncludesSource() }),
            ("busySendPreservesDraftAndStopFinalizes", { try await suite.busySendPreservesDraftAndStopFinalizes() }),
            ("typedQuestionUsesTranscriptAndAttachments", { try await suite.typedQuestionUsesTranscriptAndAttachments() }),
            ("savedMeetingExportAndSpeakerCorrectionStayScoped", { try await suite.savedMeetingExportAndSpeakerCorrectionStayScoped() }),
            ("saveFailureDoesNotClearMeeting", { try await suite.saveFailureDoesNotClearMeeting() }),
            ("disabledAutoAnswerDoesNotRequest", { try await suite.disabledAutoAnswerDoesNotRequest() }),
            ("savedQuestionUsesItsOwnContext", { try await suite.savedQuestionUsesItsOwnContext() }),
            ("draftRestoresAfterRelaunch", { try await suite.draftRestoresAfterRelaunch() }),
            ("wrapUpPersistsStructuredTasks", { try await suite.wrapUpPersistsStructuredTasks() }),
            ("continuousUpdatesStillAutosave", { try await suite.continuousUpdatesStillAutosave() }),
            ("captionMatchingRequiresMatchingSpeech", { try suite.captionMatchingRequiresMatchingSpeech() }),
            ("retryRecoversFailedAnswer", { try await suite.retryRecoversFailedAnswer() }),
            ("newMeetingArchivesAndClearsContext", { try await suite.newMeetingArchivesAndClearsContext() }),
            ("contextImportAndPackActions", { try await suite.contextImportAndPackActions() }),
            ("historySearchFavoriteDeleteAndUndo", { try await suite.historySearchFavoriteDeleteAndUndo() }),
            ("decisionAndFollowUpActions", { try await suite.decisionAndFollowUpActions() })
        ]
        for (name, run) in checks {
            do { try await run(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        guard failures == 0 else { throw CheckFailure.failed("\(failures) regression checks failed") }
        print("\(checks.count) regression checks passed")
    }
    func audioContinuesAcrossRecognitionRestarts() throws {
        var lifecycle = AudioCaptureLifecycle()
        let audioToken = lifecycle.capture
        let recognitionToken = lifecycle.recognition
        for _ in 0..<10 { lifecycle.rotateRecognition() }
        try check(lifecycle.acceptsAudio(audioToken))
        try check(lifecycle.recognition != recognitionToken)
        lifecycle.stop()
        try check(!lifecycle.acceptsAudio(audioToken))
        let restartedAudioToken = lifecycle.capture
        lifecycle.rotateRecognition()
        try check(lifecycle.acceptsAudio(restartedAudioToken))
        try check(!lifecycle.acceptsAudio(audioToken))
    }
    func captureDiagnosticsTrackStagesWithoutTranscript() throws {
        let diagnostics = CaptureDiagnostics()
        diagnostics.stage("Registering audio callback")
        diagnostics.buffer(level: 0.2)
        diagnostics.buffer(level: 0.1)
        diagnostics.reject("Format mismatch")
        diagnostics.recognitionResult()
        let snapshot = diagnostics.snapshot
        try check(snapshot.buffers == 2 && snapshot.rejectedBuffers == 1)
        try check(snapshot.peakLevel == 0.2 && snapshot.recognitionResults == 1)
        try check(snapshot.report.contains("Format mismatch"))
        diagnostics.reset()
        try check(diagnostics.snapshot == CaptureDiagnosticSnapshot())
    }
    func oldMeetingMigration() throws {
        let id = UUID()
        let data = Data("{\"meta\":{\"id\":\"\(id)\",\"title\":\"Legacy\",\"date\":0},\"context\":\"Background\",\"lines\":[{\"speaker\":\"Them\",\"text\":\"Keep this\",\"isFinal\":true}]}".utf8)
        let meeting = try JSONDecoder().decode(Meeting.self, from: data)
        try check(meeting.id == id)
        try check(meeting.lines.first?.text == "Keep this")
        try check(meeting.attachments.isEmpty)
        let roundtrip = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting))
        try check(roundtrip == meeting)
    }
    @MainActor func fullTranscriptSurvivesAndContextIncludesOversizedTail() throws {
        let store = TranscriptStore()
        for i in 0..<650 { store.appendFinal("Passage \(i)", speaker: "Alex") }
        try check(store.lines.count == 650)
        try check(store.lines.first?.text == "Passage 0")
        store.appendFinal(String(repeating: "long ", count: 4000) + "LAST WORD", speaker: "Alex")
        try check(store.recentContext(maxChars: 200).hasSuffix("LAST WORD"))
        try check(store.recentContext(maxChars: 200).count <= 200)
        let chunks = ConversationContext.chunks(store.lines)
        try check(chunks.joined().contains("Passage 0"))
        try check(chunks.joined().contains("Passage 649"))
        try check(chunks.joined().contains("LAST WORD"))
        try check(chunks.allSatisfy { $0.count <= 14000 })
    }
    func repositoryDraftAndTrashRecovery() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = MeetingRepository(root: root)
        var meeting = Meeting.empty(); meeting.meta.title = "Product review"
        meeting.attachments = [ContextAttachment(name: "brief.md", text: "Key requirements")]
        meeting.wrapUp.tasks = [ActionItem(title: "Send proposal", owner: "Alex", completed: true)]
        try await repo.write(meeting, draft: true); try await repo.write(meeting, draft: false)
        try check(try await repo.draft() == meeting)
        try check(try await repo.list().count == 1)
        try await repo.trash(meeting.id)
        try check(try await repo.list().isEmpty)
        try await repo.restore(meeting.id)
        try check(try await repo.list().first == meeting)
    }
    func localSpeechProtocolAndWAV() throws {
        let data = Data(#"{"segments":[{"text":"Hi Alex","speaker":0,"start":0},{"text":"Hello","speaker":1,"start":1}]}"#.utf8)
        let parsed = try LocalSpeechParser.segments(data)
        try check(parsed.map(\.text) == ["Hi Alex", "Hello"])
        try check(parsed.map(\.speaker) == [0, 1])
        let wav = LocalSpeechStream.wav(Data([0, 0, 1, 0]), sampleRate: 16000)
        try check(wav.count == 48 && String(data: wav.prefix(4), encoding: .utf8) == "RIFF")
        try check(wav.suffix(4) == Data([0, 0, 1, 0]))
        do {
            _ = try LocalSpeechParser.segments(Data(#"{"error":"Missing local model"}"#.utf8))
            throw CheckFailure.failed("Expected a service error")
        } catch is KuraError {}
        do {
            try LocalSpeechConfiguration(python: "", whisper: "", whisperModel: "", speakerModel: "").validate()
            throw CheckFailure.failed("Expected setup validation error")
        } catch is KuraError {}
    }
    func finalizedTranscriptTriggersQA() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = RecordingProvider()
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { provider })
        let original = model.autoQA; defer { model.autoQA = original }
        model.autoQA = true; model.alwaysOnActive = true
        model.session.context = "We plan to launch on Friday."
        model.transcript.updatePartial("What is our launch date?", speaker: "Speaker 1")
        try await Task.sleep(for: .milliseconds(1300))
        try check(provider.messages.isEmpty)
        model.transcript.commitFinal("What is our launch date?", speaker: "Speaker 1")
        try await Task.sleep(for: .milliseconds(1500))
        try check(provider.messages.contains { $0.content.contains("Friday") })
        try check(model.session.lines.contains { $0.source == "assistant" && $0.text.contains("useful answer") })
        model.alwaysOnActive = false; try await model.flush()
        let saved = try await model.meetings.repository.draft()
        try check(saved?.lines.contains { $0.source == "assistant" } == true)
    }
    func shortPauseRequiresStableTextAndLiveQuietAudio() throws {
        var turn = SpeechTurnBoundary()
        turn.observe(text: "What is two plus two", at: 10)
        turn.observe(rms: 0.1, at: 10)
        turn.observe(rms: 0, at: 10.5)
        try check(!turn.shouldFinish(at: 10.5))
        turn.observe(text: "What is two plus two", at: 11) // Same callback is not a revision.
        turn.observe(rms: 0, at: 11.3)
        try check(turn.shouldFinish(at: 11.3))
        turn.observe(text: "What is two plus two multiplied by three", at: 11.4)
        try check(!turn.shouldFinish(at: 11.4))
        turn.observe(rms: 0.1, at: 12.6)
        try check(!turn.shouldFinish(at: 12.7)) // Still talking.
        turn.observe(rms: 0, at: 13.6)
        try check(turn.shouldFinish(at: 13.6))
        try check(!turn.shouldFinish(at: 15)) // No buffers is not silence.
        turn = SpeechTurnBoundary()
        turn.observe(rms: 0, at: 20)
        try check(!turn.shouldFinish(at: 20)) // No repeated empty turns.
    }
    func conversationalTurnAnswersOnceAndAllowsFollowUp() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = RecordingProvider()
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { provider })
        let original = model.autoQA; defer { model.autoQA = original }
        model.autoQA = true; model.alwaysOnActive = true
        let text = "What is two plus two"
        model.transcript.updatePartial(text, speaker: "Unknown speaker")
        var boundary = SpeechTurnBoundary()
        boundary.observe(text: text, at: 0)
        boundary.observe(rms: 0.1, at: 0)
        boundary.observe(rms: 0, at: 1.3)
        try check(boundary.shouldFinish(at: 1.3))
        model.transcript.commitFinal(text, speaker: "Unknown speaker")
        let first = model.transcript.lines[0]
        try await Task.sleep(for: .milliseconds(400))
        try check(provider.callCount == 1)
        model.transcript.onLineFinalized?(first) // A duplicate callback must not request twice.
        try await Task.sleep(for: .milliseconds(350))
        try check(provider.callCount == 1)
        // A genuinely repeated question in a later turn is allowed.
        model.transcript.appendFinal(text, speaker: "Unknown speaker")
        try await Task.sleep(for: .milliseconds(400))
        try check(provider.callCount == 2)
        try check(model.session.lines.filter { $0.source == "assistant" }.count == 2)
        model.alwaysOnActive = false; try await model.flush()
    }
    func busyAutoAnswerKeepsLatestQuestion() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = RecordingProvider(); provider.responseDelay = .milliseconds(700)
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { provider })
        let original = model.autoQA; defer { model.autoQA = original }
        model.autoQA = true; model.alwaysOnActive = true
        model.question = "Typed question"; model.send()
        model.transcript.appendFinal("When is the launch", speaker: "Alex")
        try check(model.autoAnswerStatus == "Answer queued…")
        try await Task.sleep(for: .milliseconds(100))
        model.transcript.appendFinal("Who sends the brief", speaker: "Alex")
        try await Task.sleep(for: .milliseconds(850))
        try check(provider.callCount == 2)
        try check(provider.messages.first?.content.contains("Request:\nAnswer this spoken question briefly: Who sends the brief") == true)
        model.stopAnswer(); model.alwaysOnActive = false; try await model.flush()
    }
    func newerQuestionInterruptsStaleAutoAnswer() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = RecordingProvider(); provider.suspended = true
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { provider })
        let original = model.autoQA; defer { model.autoQA = original }
        model.autoQA = true; model.alwaysOnActive = true
        model.transcript.appendFinal("What is earth", speaker: "Alex")
        try await Task.sleep(for: .milliseconds(500))
        try check(provider.callCount == 1 && model.status == .streaming)
        model.transcript.appendFinal("What is the moon", speaker: "Alex")
        try await Task.sleep(for: .milliseconds(700))
        try check(provider.callCount == 2)
        try check(provider.messages.first?.content.contains("moon") == true)
        model.stopAnswer()
        try await model.flush()
    }
    func pendingAutoAnswerCancelsWhenDisabledOrPaused() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = RecordingProvider()
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { provider })
        let original = model.autoQA; defer { model.autoQA = original }
        model.autoQA = true; model.alwaysOnActive = true
        model.transcript.appendFinal("What is the plan", speaker: "You")
        model.transcript.appendFinal("What is the plan", speaker: "Kura", source: "assistant")
        try await Task.sleep(for: .milliseconds(350))
        try check(provider.callCount == 0)
        model.transcript.appendFinal("What is the plan", speaker: "Alex")
        model.autoQA = false
        try await Task.sleep(for: .milliseconds(350))
        try check(provider.callCount == 0 && model.autoAnswerStatus.isEmpty)
        model.autoQA = true
        model.transcript.appendFinal("What is the plan", speaker: "Alex")
        model.stopCapture()
        try await Task.sleep(for: .milliseconds(350))
        try check(provider.callCount == 0 && model.autoAnswerStatus.isEmpty)
        try await model.flush()
    }
    func spokenQuestionDetection() throws {
        for text in ["What is 2+2", "Who sends the brief", "When is launch", "Where should this go", "Could you explain caching", "Tell me about queues", "Is there a deadline", "Ready for launch?",
                     "Hey team quick question what is the capital of France", "So how do we handle retries", "Before we wrap, when is the deadline",
                     "Design simple rate limiter", "Summarize the discussion so far"] {
            try check(SpokenQuestion.matches(text))
        }
        for text in ["", "What", "We launch on Friday", "The answer is four", "I know what you mean"] {
            try check(!SpokenQuestion.matches(text))
        }
    }
    func spokenQuestionLLMFallback() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = RecordingProvider()
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { provider })
        let original = model.autoQA; defer { model.autoQA = original }
        model.autoQA = true; model.alwaysOnActive = true
        // Regex-miss phrasing: classifier says yes → classify call + answer call.
        provider.response = "yes"
        model.transcript.appendFinal("Never counts lots of run time", speaker: "Alex")
        try await Task.sleep(for: .milliseconds(900))
        try check(provider.callCount == 2)
        // Classifier says no → no answer, and each line is classified only once.
        provider.response = "no"
        model.transcript.appendFinal("Some other garbled sentence entirely", speaker: "Alex")
        try await Task.sleep(for: .milliseconds(600))
        try check(provider.callCount == 3)
        try await model.flush()
    }
    func localWorkerDrainsFinalAudioIntoQA() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("fixture".utf8).write(to: root.appendingPathComponent("model.bin"))
        try Data("fixture".utf8).write(to: root.appendingPathComponent("config.yaml"))
        let provider = RecordingProvider()
        let model = OverlayViewModel(root: root.appendingPathComponent("meetings"), restore: false, providerFactory: { provider })
        let original = model.autoQA; defer { model.autoQA = original }
        model.autoQA = true; model.alwaysOnActive = true
        let worker = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/local_worker_stub.py")
        let stream = try LocalSpeechStream(configuration: LocalSpeechConfiguration(python: "/usr/bin/python3", whisper: "/usr/bin/true", whisperModel: root.appendingPathComponent("model.bin").path, speakerModel: root.path), sampleRate: 16000, workerURL: worker,
                                           onSegments: { segments in Task { @MainActor in for line in segments { model.transcript.appendFinal(line.text, speaker: "Speaker \(line.speaker + 1)") } } },
                                           onError: { error in Task { @MainActor in model.lastError = error } })
        stream.send(Data(repeating: 0, count: 32000)) // Less than a full window: Stop must flush it.
        await withCheckedContinuation { continuation in stream.stop { continuation.resume() } }
        try await Task.sleep(for: .milliseconds(1500))
        try check(model.lastError.isEmpty)
        try check(model.session.lines.contains { $0.text == "What is the launch date?" })
        try check(provider.messages.contains { $0.content.contains("launch date") })
        model.alwaysOnActive = false; try await model.flush()
    }
    func providerCatalogAndReasoningPayloads() throws {
        let data = Data(#"{"data":[{"id":"claude-test","display_name":"Claude test","capabilities":{"effort":{"low":{"supported":true},"max":{"supported":false}},"thinking":{"types":{"adaptive":{"supported":true}}}}}],"has_more":true,"last_id":"claude-test"}"#.utf8)
        let page = try ModelCatalog.parse(data)
        try check(page.models.first?.efforts == ["low"] && page.models.first?.adaptiveThinking == true)
        try check(page.next == "claude-test")
        let openAI = OpenAIResponsesProvider(apiKey: "dummy", model: "test", effort: "low").requestBody(messages: [], system: "context")
        try check((openAI["reasoning"] as? [String: String])?["effort"] == "low")
        try check(openAI["store"] as? Bool == false)
        try check(OpenAIResponsesProvider(apiKey: "", model: "test").requestBody(messages: [], system: "")["reasoning"] == nil)
        let claude = AnthropicProvider(apiKey: "dummy", model: "test", effort: "high", adaptiveThinking: true).requestBody(messages: [], system: "")
        try check((claude["output_config"] as? [String: String])?["effort"] == "high")
        try check((claude["thinking"] as? [String: String])?["type"] == "adaptive")
        try check(try OpenAIResponsesProvider.textDelta(Data(#"{"type":"response.output_text.delta","delta":"Hello"}"#.utf8)) == "Hello")
        do {
            _ = try OpenAIResponsesProvider.textDelta(Data(#"{"type":"response.incomplete"}"#.utf8))
            throw CheckFailure.failed("Expected incomplete-response error")
        } catch is KuraError {}
    }
    func speakerCuesDoNotGuessFromParticipantLists() throws {
        try check(SpeakerCueParser.suggestion(in: ["Alex", "Jamie", "Participants (2)"]) == nil)
        try check(SpeakerCueParser.suggestion(in: ["Speaking: Alex"]) == "Alex")
        try check(SpeakerCueParser.suggestion(in: ["Jamie is speaking"]) == "Jamie")
    }
    func structuredWrapUpIncludesSource() throws {
        let id = UUID()
        let json = "{\"summary\":\"Launch plan\",\"decisions\":[\"Ship Friday\"],\"questions\":[],\"tasks\":[{\"title\":\"Send update\",\"owner\":\"Alex\",\"sourceID\":\"\(id)\"}]}"
        let wrap = try WrapUpGenerator.parse("```json\n" + json + "\n```")
        try check(wrap.tasks.first?.sourceID == id)
        try check(wrap.tasks.first?.deadline == "")
    }
    @MainActor func busySendPreservesDraftAndStopFinalizes() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = RecordingProvider(); provider.suspended = true
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { provider })
        model.question = "First question"; model.send()
        model.question = "Do not lose this"; model.send()
        try check(model.question == "Do not lose this")
        model.stopAnswer()
        try check(model.status == .idle)
        try check(model.current.lines.allSatisfy(\.isFinal))
        try await model.flush()
    }
    @MainActor func typedQuestionUsesTranscriptAndAttachments() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = RecordingProvider()
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { provider })
        model.transcript.appendFinal("The deadline is Friday.", speaker: "Alex")
        model.session.attachments = [ContextAttachment(name: "brief", text: "Customer needs SSO")]
        model.question = "What should I prioritize?"; model.send()
        for _ in 0..<20 { await Task.yield() }
        try check(provider.messages.first?.content.contains("The deadline is Friday.") == true)
        try check(provider.messages.first?.content.contains("Customer needs SSO") == true)
        model.stopAnswer(); try await model.flush()
    }
    @MainActor func savedMeetingExportAndSpeakerCorrectionStayScoped() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let model = OverlayViewModel(root: root, restore: false)
        model.session.meta.title = "Live"
        var past = Meeting.empty(); past.meta.title = "Past"
        let line = TranscriptLine(speaker: "Speaker 1", text: "Send the proposal")
        past.lines = [line, TranscriptLine(speaker: "Speaker 1", text: "By Friday")]
        model.selected = past
        model.correctLine(line, text: "Send the revised proposal", speaker: "Alex", renameAll: true)
        try check(model.current.lines.allSatisfy { $0.speaker == "Alex" })
        try check(model.exportText().contains("# Past"))
        try check(!model.exportText().contains("# Live"))
        try check(model.session.lines.isEmpty)
        try await model.flush()
    }
    @MainActor func saveFailureDoesNotClearMeeting() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: file)
        let model = OverlayViewModel(root: file, restore: false)
        model.transcript.appendFinal("Keep my notes", speaker: "Alex")
        model.startNewSession()
        for _ in 0..<100 where model.transitioning { try await Task.sleep(for: .milliseconds(10)) }
        try check(model.session.lines.first?.text == "Keep my notes")
        try check(!model.lastError.isEmpty)
    }
    func disabledAutoAnswerDoesNotRequest() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = RecordingProvider()
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { provider })
        let original = model.autoQA; defer { model.autoQA = original }
        model.autoQA = false; model.alwaysOnActive = true
        model.transcript.updatePartial("What should we do next?", speaker: "Alex")
        model.transcript.commitFinal("What should we do next?", speaker: "Alex")
        try await Task.sleep(for: .milliseconds(1300))
        try check(provider.messages.isEmpty)
        model.alwaysOnActive = false; try await model.flush()
    }
    func savedQuestionUsesItsOwnContext() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = RecordingProvider()
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { provider })
        model.session.context = "LIVE SECRET"
        var past = Meeting.empty(); past.context = "PAST BACKGROUND"
        past.lines = [TranscriptLine(speaker: "Jamie", text: "PAST CONVERSATION")]
        model.selected = past; model.question = "Recap this"; model.send()
        for _ in 0..<30 where model.status == .streaming { try await Task.sleep(for: .milliseconds(10)) }
        let request = provider.messages.first?.content ?? ""
        try check(request.contains("PAST BACKGROUND") && request.contains("PAST CONVERSATION"))
        try check(!request.contains("LIVE SECRET"))
        try check(model.session.lines.isEmpty)
        model.stopAnswer(); try await model.flush()
    }
    func draftRestoresAfterRelaunch() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let first = OverlayViewModel(root: root, restore: false)
        first.session.meta.title = "Restorable"
        first.transcript.appendFinal("Keep the complete discussion", speaker: "Alex")
        first.session.attachments = [ContextAttachment(name: "brief", text: "Remember this")]
        try await first.flush()
        let restored = OverlayViewModel(root: root)
        for _ in 0..<100 where restored.restoring { try await Task.sleep(for: .milliseconds(10)) }
        try check(restored.session.meta.title == "Restorable")
        try check(restored.session.lines.first?.speaker == "Alex")
        try check(restored.session.attachments.first?.text == "Remember this")
        try await restored.flush()
    }
    func wrapUpPersistsStructuredTasks() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = RecordingProvider()
        provider.response = #"{"summary":"We agreed on a launch.","decisions":["Launch Friday"],"questions":[],"tasks":[{"title":"Send brief","owner":"Alex"}]}"#
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { provider })
        model.transcript.appendFinal("Launch Friday. Alex will send the brief.", speaker: "You")
        model.session.wrapUp.tasks = [ActionItem(title: "Check onboarding", completed: true)]
        model.session.wrapUp.decisions = ["User-confirmed decision"]
        model.generateWrapUp()
        for _ in 0..<100 where model.status == .streaming { try await Task.sleep(for: .milliseconds(10)) }
        try check(model.lastError.isEmpty)
        try check(model.session.wrapUp.tasks.count == 2)
        try check(model.session.wrapUp.tasks.contains { $0.completed })
        try check(model.session.wrapUp.decisions.contains("User-confirmed decision"))
        try check(model.meetings.meetings.count == 1)
        try await model.flush()
    }
    func continuousUpdatesStillAutosave() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let model = OverlayViewModel(root: root, restore: false)
        for index in 0..<10 {
            model.transcript.updatePartial("Continuous speech \(index)", speaker: "Alex")
            try await Task.sleep(for: .milliseconds(100))
        }
        let draft = try await model.meetings.repository.draft()
        try check(draft?.lines.isEmpty == false)
        try await model.flush()
    }
    func captionMatchingRequiresMatchingSpeech() throws {
        let speech = "Please send the revised proposal before Friday"
        try check(SpeakerCueParser.captionSuggestion(for: speech, lines: ["Alex", "Please send the revised proposal before Friday"]) == "Alex")
        try check(SpeakerCueParser.captionSuggestion(for: speech, lines: ["Alex", "An entirely different conversation is visible here"]) == nil)
        try check(SpeakerCueParser.captionSuggestion(for: "Thanks", lines: ["Alex", "Thanks"]) == nil)
    }
    func retryRecoversFailedAnswer() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = RecordingProvider(); provider.failing = true
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { provider })
        model.question = "Explain the next step"; model.send()
        for _ in 0..<100 where model.status == .streaming { try await Task.sleep(for: .milliseconds(10)) }
        try check(model.canRetry && !model.lastError.isEmpty)
        provider.failing = false; model.retry()
        for _ in 0..<100 where model.status == .streaming { try await Task.sleep(for: .milliseconds(10)) }
        try check(model.lastError.isEmpty && model.current.lines.last?.text == provider.response)
        try await model.flush()
    }
    func newMeetingArchivesAndClearsContext() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let model = OverlayViewModel(root: root, restore: false)
        model.session.context = "Only this session"
        model.transcript.appendFinal("Keep this meeting", speaker: "Alex")
        let old = model.session.id
        model.startNewSession()
        for _ in 0..<100 where model.transitioning { try await Task.sleep(for: .milliseconds(10)) }
        try check(model.session.id != old && model.session.context.isEmpty && model.transcript.lines.isEmpty)
        try check(model.meetings.meetings.first?.context == "Only this session")
        try await model.flush()
    }
    func contextImportAndPackActions() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("brief.md")
        try Data("Customer needs searchable notes".utf8).write(to: fixture)
        let model = OverlayViewModel(root: root.appendingPathComponent("meetings"), restore: false)
        model.importFiles([fixture])
        for _ in 0..<100 where model.importing { try await Task.sleep(for: .milliseconds(10)) }
        try check(model.current.attachments.first?.name == "brief.md")
        model.session.context = "Project notes"; model.saveContextPack("Project")
        for _ in 0..<100 where model.meetings.packs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        guard let pack = model.meetings.packs.first else { throw CheckFailure.failed("Pack not saved") }
        model.session.context = ""; model.session.attachments = []; model.applyPack(pack)
        try check(model.session.context == "Project notes" && model.session.attachments.count == 1)
        model.session.attachments.removeAll()
        try check(!model.session.contextForAI.contains("Customer needs searchable notes"))
        try await model.flush()
    }
    func historySearchFavoriteDeleteAndUndo() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let model = OverlayViewModel(root: root, restore: false)
        var saved = Meeting.empty(); saved.meta.title = "Research"; saved.favorite = true; saved.tags = "Product"
        saved.lines = [TranscriptLine(speaker: "Alex", text: "Unique searchable sentence")]
        try await model.meetings.save(saved)
        model.search = "searchable sentence"; model.favoriteOnly = true
        try check(model.filteredMeetings.count == 1)
        model.search = "not present"; try check(model.filteredMeetings.isEmpty)
        model.search = ""; model.viewMeeting(saved)
        for _ in 0..<100 where model.transitioning { try await Task.sleep(for: .milliseconds(10)) }
        try check(model.selected?.id == saved.id)
        model.backToLive()
        for _ in 0..<100 where model.transitioning { try await Task.sleep(for: .milliseconds(10)) }
        try check(model.selected == nil)
        model.deleteMeeting(saved)
        for _ in 0..<100 where model.lastDeleted == nil { try await Task.sleep(for: .milliseconds(10)) }
        try check(model.meetings.meetings.isEmpty)
        model.undoDelete()
        for _ in 0..<100 where model.lastDeleted != nil { try await Task.sleep(for: .milliseconds(10)) }
        try check(model.meetings.meetings.first?.id == saved.id)
        try await model.flush()
    }
    func decisionAndFollowUpActions() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = RecordingProvider()
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { provider })
        model.question = "Launch Friday"; model.captureDecision()
        try check(model.current.wrapUp.decisions == ["Launch Friday"] && model.question.isEmpty)
        model.assist(.followUps)
        for _ in 0..<100 where model.status == .streaming { try await Task.sleep(for: .milliseconds(10)) }
        try check(model.current.wrapUp.followUp == provider.response && model.tab == .wrapUp)
        model.assist(.recap)
        for _ in 0..<100 where model.status == .streaming { try await Task.sleep(for: .milliseconds(10)) }
        try check(provider.messages.first?.content.contains("Briefly recap") == true)
        model.assist(.whatToSay)
        for _ in 0..<100 where model.status == .streaming { try await Task.sleep(for: .milliseconds(10)) }
        try check(provider.messages.first?.content.contains("Suggest a useful") == true)
        try await model.flush()
    }
}

private enum CheckFailure: Error { case failed(String) }
private func check(_ condition: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    if !condition { throw CheckFailure.failed("\(file):\(line)") }
}
