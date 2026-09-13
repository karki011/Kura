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
    var usage: LLMUsage?
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
    func stream(messages: [LLMMessage], system: String, onUsage: (@Sendable (LLMUsage) -> Void)?) -> AsyncThrowingStream<String, Error> {
        guard let usage, let onUsage else { return stream(messages: messages, system: system) }
        let base = stream(messages: messages, system: system)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await delta in base { continuation.yield(delta) }
                    onUsage(usage); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
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
            ("busySendPreservesDraftAndStopFinalizes", { try await suite.busySendPreservesDraftAndStopFinalizes() }),
            ("typedQuestionUsesTranscriptAndAttachments", { try await suite.typedQuestionUsesTranscriptAndAttachments() }),
            ("savedMeetingExportAndSpeakerCorrectionStayScoped", { try await suite.savedMeetingExportAndSpeakerCorrectionStayScoped() }),
            ("saveFailureDoesNotClearMeeting", { try await suite.saveFailureDoesNotClearMeeting() }),
            ("disabledAutoAnswerDoesNotRequest", { try await suite.disabledAutoAnswerDoesNotRequest() }),
            ("savedQuestionUsesItsOwnContext", { try await suite.savedQuestionUsesItsOwnContext() }),
            ("draftRestoresAfterRelaunch", { try await suite.draftRestoresAfterRelaunch() }),
            ("wrapUpNotesPersistAndLegacySeedsOnce", { try await suite.wrapUpNotesPersistAndLegacySeedsOnce() }),
            ("wrapUpGenerationStreamsNotes", { try await suite.wrapUpGenerationStreamsNotes() }),
            ("continuousUpdatesStillAutosave", { try await suite.continuousUpdatesStillAutosave() }),
            ("captionMatchingRequiresMatchingSpeech", { try suite.captionMatchingRequiresMatchingSpeech() }),
            ("incrementalCommitKeepsLongMonologue", { try suite.incrementalCommitKeepsLongMonologue() }),
            ("retryRecoversFailedAnswer", { try await suite.retryRecoversFailedAnswer() }),
            ("newMeetingArchivesAndClearsContext", { try await suite.newMeetingArchivesAndClearsContext() }),
            ("contextImportAndPackActions", { try await suite.contextImportAndPackActions() }),
            ("historySearchFavoriteDeleteAndUndo", { try await suite.historySearchFavoriteDeleteAndUndo() }),
            ("decisionAndFollowUpActions", { try await suite.decisionAndFollowUpActions() }),
            ("speakerBindingEvidenceAndUndo", { try await suite.speakerBindingEvidenceAndUndo() }),
            ("onDeviceCommitReplacesOpenPartialInOrder", { try suite.onDeviceCommitReplacesOpenPartialInOrder() }),
            ("customVocabularyTermParsing", { try suite.customVocabularyTermParsing() }),
            ("deepModelSettingsRouteByPurpose", { try await suite.deepModelSettingsRouteByPurpose() }),
            ("deletingViewedMeetingLandsOnFreshSession", { try await suite.deletingViewedMeetingLandsOnFreshSession() }),
            ("trashedMeetingStaysGoneAfterRelaunch", { try await suite.trashedMeetingStaysGoneAfterRelaunch() }),
            ("realtimeSessionPayload", { try suite.realtimeSessionPayload() }),
            ("realtimeServerEventParsing", { try suite.realtimeServerEventParsing() }),
            ("realtimeAudioEncodingAndRotation", { try suite.realtimeAudioEncodingAndRotation() }),
            ("usageParsingPerProvider", { try suite.usageParsingPerProvider() }),
            ("modelPricingAndCostMath", { try suite.modelPricingAndCostMath() }),
            ("answerMetaAndSpendRecorded", { try await suite.answerMetaAndSpendRecorded() }),
            ("wrapUpUsageAddsToSpend", { try await suite.wrapUpUsageAddsToSpend() }),
            ("answerMetaCodableCompatibility", { try suite.answerMetaCodableCompatibility() })
        ]
        for (name, run) in checks {
            do { try await run(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
            fflush(stdout)
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
        // A wrap-up saved before the freeform notes field decodes with empty notes.
        let withWrapUp = try JSONDecoder().decode(Meeting.self, from: Data("{\"meta\":{\"id\":\"\(id)\",\"title\":\"Legacy\",\"date\":0},\"wrapUp\":{\"summary\":\"Old summary\",\"decisions\":[\"D\"],\"tasks\":[{\"id\":\"\(UUID())\",\"title\":\"T\",\"owner\":\"\",\"deadline\":\"\",\"completed\":false}]}}".utf8))
        try check(withWrapUp.wrapUp.summary == "Old summary" && withWrapUp.wrapUp.tasks.count == 1 && withWrapUp.wrapUp.notes.isEmpty)
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
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { _ in provider })
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
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { _ in provider })
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
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { _ in provider })
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
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { _ in provider })
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
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { _ in provider })
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
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { _ in provider })
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
    func incrementalCommitKeepsLongMonologue() throws {
        var committer = IncrementalTranscriptCommitter()
        // Nothing to stabilize against on the first partial.
        try check(committer.observe("Hello") == nil)
        // Small stable growth stays open to revision.
        try check(committer.observe("Hello everyone") == nil)
        let sentence = "Hello everyone, welcome to the review. Today we walk through the launch plan and the open risks for Friday. "
        let grown = sentence + "Then we assig"
        try check(committer.observe(grown) == nil)
        // Once the stable head is long enough, it commits at the sentence boundary.
        let chunk = committer.observe(grown + "n owners for eac")
        try check(chunk == "Hello everyone, welcome to the review. Today we walk through the launch plan and the open risks for Friday.")
        try check(committer.remainder(for: grown + "n owners for eac") == "Then we assign owners for eac")
        // Tail revision after a commit keeps committed text intact.
        try check(committer.remainder(for: sentence + "Then we assigned somebody") == "Then we assigned somebody")
        // Wholesale revision resyncs instead of stalling.
        try check(committer.observe("Completely different words now.") == nil)
    }
    func localWorkerDrainsFinalAudioIntoQA() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("fixture".utf8).write(to: root.appendingPathComponent("model.bin"))
        try Data("fixture".utf8).write(to: root.appendingPathComponent("config.yaml"))
        let provider = RecordingProvider()
        let model = OverlayViewModel(root: root.appendingPathComponent("meetings"), restore: false, providerFactory: { _ in provider })
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
    @MainActor func busySendPreservesDraftAndStopFinalizes() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = RecordingProvider(); provider.suspended = true
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { _ in provider })
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
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { _ in provider })
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
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { _ in provider })
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
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { _ in provider })
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
    func wrapUpNotesPersistAndLegacySeedsOnce() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = RecordingProvider()
        provider.response = "## Summary\n\nLaunch agreed for Friday."
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { _ in provider })
        model.transcript.appendFinal("Launch Friday. Alex will send the brief.", speaker: "You")
        model.generateWrapUp()
        for _ in 0..<100 where model.status == .streaming { try await Task.sleep(for: .milliseconds(10)) }
        try check(model.lastError.isEmpty)
        try check(model.session.wrapUp.notes == provider.response)
        try check(model.meetings.meetings.count == 1)
        try await model.flush()
        let draft = try await model.meetings.repository.draft()
        try check(draft?.wrapUp.notes == provider.response)
        // Legacy structured content seeds into notes once, then never overwrites edits.
        model.session.wrapUp = MeetingWrapUp()
        model.session.wrapUp.summary = "Legacy summary"
        model.session.wrapUp.decisions = ["Legacy decision"]
        model.session.wrapUp.tasks = [ActionItem(title: "Send proposal", owner: "Alex", deadline: "Friday", completed: true)]
        model.session.wrapUp.followUp = "Legacy follow-up"
        model.seedWrapUpNotesIfNeeded()
        let seeded = model.session.wrapUp.notes
        try check(seeded.contains("## Summary") && seeded.contains("Legacy summary"))
        try check(seeded.contains("## Decisions") && seeded.contains("- Legacy decision"))
        try check(seeded.contains("- [x] Send proposal — Alex (Friday)"))
        try check(seeded.contains("## Follow-up draft") && seeded.contains("Legacy follow-up"))
        model.session.wrapUp.notes = "My edits"
        model.seedWrapUpNotesIfNeeded()
        try check(model.session.wrapUp.notes == "My edits")
        try await model.flush()
    }
    @MainActor func wrapUpGenerationStreamsNotes() async throws {
        let defaults = UserDefaults.standard
        let keys = ["provider", "deepModelEnabled", "anthropicModel", "deepAnthropicModel"]
        let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer { for (key, value) in saved { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        defaults.set("Anthropic", forKey: "provider")
        defaults.set(false, forKey: "deepModelEnabled")
        defaults.set("claude-sonnet-4-5", forKey: "anthropicModel")
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = RecordingProvider()
        provider.response = "## Summary\n\nStreamed wrap-up text."
        provider.usage = LLMUsage(inputTokens: 1000, outputTokens: 100)
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { _ in provider })
        model.transcript.appendFinal("Launch Friday.", speaker: "Alex")
        model.generateWrapUp()
        for _ in 0..<100 where model.status == .streaming { try await Task.sleep(for: .milliseconds(10)) }
        try check(model.status == .idle && model.lastError.isEmpty)
        try check(model.tab == .wrapUp)
        try check(model.session.wrapUp.notes == provider.response)
        try check(provider.messages.first?.content.contains("Launch Friday.") == true)
        try check(abs(model.session.aiSpendUSD - 0.0045) < 0.000001)
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
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { _ in provider })
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
    @MainActor func speakerBindingEvidenceAndUndo() async throws {
        // Pure tracker: one coincidence never binds; evidence split across slots never binds.
        var tracker = SpeakerBindingTracker()
        tracker.record(name: "Alex", slot: "Speaker 1")
        try check(tracker.confirmedSlot(for: "Alex") == nil)
        tracker.record(name: "Alex", slot: "Speaker 2")
        try check(tracker.confirmedSlot(for: "Alex") == nil)
        tracker.record(name: "Alex", slot: "Speaker 1")
        try check(tracker.confirmedSlot(for: "Alex") == "Speaker 1")
        // Tied evidence on two slots stays ambiguous.
        var tied = SpeakerBindingTracker()
        tied.record(name: "Jamie", slot: "Speaker 1"); tied.record(name: "Jamie", slot: "Speaker 1")
        tied.record(name: "Jamie", slot: "Speaker 2"); tied.record(name: "Jamie", slot: "Speaker 2")
        try check(tied.confirmedSlot(for: "Jamie") == nil)

        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let model = OverlayViewModel(root: root, restore: false)
        model.transcript.appendFinal("We should ship on Friday", speaker: "Speaker 1")
        // A single coincidence never renames.
        model.recordSpeakerCue(name: "Alex", slot: "Speaker 1")
        try check(model.transcript.lines.last?.speaker == "Speaker 1")
        try check(model.lastAutoBinding == nil)
        // Two coincidences on the same slot bind and rename past lines, with notice.
        model.recordSpeakerCue(name: "Alex", slot: "Speaker 1")
        try check(model.transcript.lines.last?.speaker == "Alex")
        try check(model.lastAutoBinding != nil && model.notice.contains("Alex"))
        // The mic speaker is never auto-renamed.
        model.recordSpeakerCue(name: "Alex", slot: "You")
        model.recordSpeakerCue(name: "Alex", slot: "You")
        try check(model.lastAutoBinding?.slot == "Speaker 1")
        // A conflicting name never overrides a bound slot.
        model.recordSpeakerCue(name: "Jamie", slot: "Speaker 1")
        model.recordSpeakerCue(name: "Jamie", slot: "Speaker 1")
        try check(model.transcript.lines.last?.speaker == "Alex")
        // Undo restores the slot label and clears the evidence so one stray cue does not rebind.
        model.undoAutoBinding()
        try check(model.transcript.lines.last?.speaker == "Speaker 1")
        try check(model.lastAutoBinding == nil)
        model.recordSpeakerCue(name: "Alex", slot: "Speaker 1")
        try check(model.transcript.lines.last?.speaker == "Speaker 1")
        model.recordSpeakerCue(name: "Alex", slot: "Speaker 1")
        try check(model.transcript.lines.last?.speaker == "Alex")
        try await model.flush()
    }
    @MainActor func onDeviceCommitReplacesOpenPartialInOrder() throws {
        let store = TranscriptStore()
        store.updatePartial("Hello ever", speaker: "Unknown speaker")
        store.discardOpenSpeechPartials()
        store.appendFinal("Hello everyone", speaker: "Speaker 1")
        store.updatePartial("Thanks for", speaker: "Unknown speaker")
        store.discardOpenSpeechPartials()
        store.appendFinal("Thanks for joining", speaker: "Speaker 2")
        store.updatePartial("Back to you", speaker: "Unknown speaker")
        store.discardOpenSpeechPartials()
        store.appendFinal("Back to the roadmap", speaker: "Speaker 1")
        // Each utterance is its own bubble in conversation order — no stale
        // partial bubble left behind rewriting old speech mid-transcript.
        try check(store.lines.map(\.speaker) == ["Speaker 1", "Speaker 2", "Speaker 1"])
        try check(store.lines.map(\.text) == ["Hello everyone", "Thanks for joining", "Back to the roadmap"])
        try check(store.lines.allSatisfy(\.isFinal))
        // The mic speaker's open partial belongs to a different recognizer and survives.
        store.updatePartial("My own thought", speaker: "You")
        store.discardOpenSpeechPartials()
        store.appendFinal("Next point", speaker: "Speaker 1")
        try check(store.lines.contains { $0.speaker == "You" && !$0.isFinal })
        try check(store.lines.last?.text == "Next point")
    }
    func customVocabularyTermParsing() throws {
        try check(CustomVocabulary.parseTerms("") == [])
        try check(CustomVocabulary.parseTerms("  \n , \n") == [])
        try check(CustomVocabulary.parseTerms("Kura, Parakeet\nSubash Karki") == ["Kura", "Parakeet", "Subash Karki"])
        try check(CustomVocabulary.parseTerms("kura\nKURA, Kura ,") == ["kura"])
        try check(CustomVocabulary.parseTerms(" LS-EEND ,,\nFluidAudio\t") == ["LS-EEND", "FluidAudio"])
    }
    @MainActor func deepModelSettingsRouteByPurpose() async throws {
        let defaults = UserDefaults.standard
        let keys = ["provider", "deepModelEnabled", "deepOpenAIModel", "deepOpenAIEffort", "directOpenAIModel", "directOpenAIEffort"]
        let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer { for (key, value) in saved { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        defaults.set("OpenAI", forKey: "provider")
        defaults.set("gpt-answer", forKey: "directOpenAIModel")
        defaults.set("low", forKey: "directOpenAIEffort")
        // Deep off: both purposes resolve to the answer model.
        defaults.set(false, forKey: "deepModelEnabled")
        try check(SettingsStore.shared.modelConfig(deep: true).model == "gpt-answer")
        // Deep on without a model override: same model, higher effort.
        defaults.set(true, forKey: "deepModelEnabled")
        let raised = SettingsStore.shared.modelConfig(deep: true)
        try check(raised.model == "gpt-answer" && raised.effort == "high")
        // Deep on with an override model; live answers still use the fast one.
        defaults.set("gpt-deep", forKey: "deepOpenAIModel")
        try check(SettingsStore.shared.modelConfig(deep: true).model == "gpt-deep")
        try check(SettingsStore.shared.modelConfig(deep: false).model == "gpt-answer")

        // Routing: wrap-up actions use the deep provider; auto answers the fast one.
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = RecordingProvider()
        var deepFlags: [Bool] = []
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { deep in deepFlags.append(deep); return provider })
        model.transcript.appendFinal("We decided to launch on Friday.", speaker: "Speaker 1")
        model.assist(.recap)
        for _ in 0..<100 where model.status == .streaming { try await Task.sleep(for: .milliseconds(10)) }
        try check(deepFlags.last == true)
        let original = model.autoQA; defer { model.autoQA = original }
        model.autoQA = true; model.alwaysOnActive = true
        model.transcript.appendFinal("What is the launch date?", speaker: "Speaker 1")
        for _ in 0..<200 where deepFlags.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        try check(deepFlags.last == false)
        model.alwaysOnActive = false; try await model.flush()
    }
    func realtimeSessionPayload() throws {
        let payload = RealtimeWire.sessionUpdate(instructions: RealtimeWire.sessionInstructions(context: "Goal: ship Friday"))
        try check(payload["type"] as? String == "session.update")
        let session = payload["session"] as? [String: Any]
        try check(session?["type"] as? String == "realtime")
        try check(session?["output_modalities"] as? [String] == ["text"])
        try check((session?["instructions"] as? String)?.contains("ship Friday") == true)
        let audio = session?["audio"] as? [String: Any]
        let input = audio?["input"] as? [String: Any]
        let format = input?["format"] as? [String: Any]
        try check(format?["type"] as? String == "audio/pcm" && format?["rate"] as? Int == 24000)
        let transcription = input?["transcription"] as? [String: Any]
        try check((transcription?["model"] as? String)?.isEmpty == false)
        let turn = input?["turn_detection"] as? [String: Any]
        try check(turn?["type"] as? String == "semantic_vad")
        try check(turn?["create_response"] as? Bool == false && turn?["interrupt_response"] as? Bool == false)
        // Sessions cap at 60 minutes; rotation must trigger earlier.
        try check(RealtimeWire.rotateAfterSeconds < RealtimeWire.sessionLimitSeconds)
        let create = RealtimeWire.responseCreate(instructions: RealtimeWire.answerInstructions(question: "When is launch?"))
        try check(create["type"] as? String == "response.create")
        let response = create["response"] as? [String: Any]
        let answerInstructions = response?["instructions"] as? String
        try check(answerInstructions?.contains("When is launch?") == true)
        // Anti-hallucination guardrails: answer only from what was said, with an
        // explicit "wasn't mentioned" escape hatch, and stay brief.
        try check(answerInstructions?.contains("only what was actually said") == true)
        try check(answerInstructions?.contains("wasn't mentioned in the meeting") == true)
        try check(answerInstructions?.contains("never invent") == true)
        try check(answerInstructions?.contains("sentence or two") == true)
        // The session-level instructions carry the same constraint plus the copilot prompt.
        let sessionInstructions = RealtimeWire.sessionInstructions(context: "Goal: ship Friday")
        try check(sessionInstructions.contains("Never invent a speaker name, decision, owner, or deadline"))
        try check(sessionInstructions.contains("only from what was actually said"))
        try check(response?["output_modalities"] as? [String] == ["text"])
        // Payloads must round-trip through JSONSerialization.
        let data = try JSONSerialization.data(withJSONObject: payload)
        try check((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["type"] as? String == "session.update")
    }
    func realtimeServerEventParsing() throws {
        let delta = RealtimeWire.parse(Data(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"a","delta":"Hello"}"#.utf8))
        try check(delta == .transcriptDelta(itemID: "a", delta: "Hello"))
        let done = RealtimeWire.parse(Data(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":"Hello everyone"}"#.utf8))
        try check(done == .transcriptCompleted("Hello everyone"))
        let text = RealtimeWire.parse(Data(#"{"type":"response.output_text.delta","delta":"Four"}"#.utf8))
        try check(text == .textDelta("Four"))
        let finished = RealtimeWire.parse(Data(#"{"type":"response.done","response":{"status":"completed"}}"#.utf8))
        try check(finished == .responseDone(status: "completed"))
        let failure = RealtimeWire.parse(Data(#"{"type":"error","error":{"message":"boom"}}"#.utf8))
        try check(failure == .error("boom"))
        try check(RealtimeWire.parse(Data(#"{"type":"rate_limits.updated"}"#.utf8)) == .ignored("rate_limits.updated"))
        try check(RealtimeWire.parse(Data("not json".utf8)) == .ignored(""))
    }
    func realtimeAudioEncodingAndRotation() throws {
        let base64 = RealtimeWire.pcm16Base64([0, 1, -1, 0.5])
        try check(Data(base64Encoded: base64) == Data([0x00, 0x00, 0xFF, 0x7F, 0x00, 0x80, 0xFF, 0x3F]))
        try check(RealtimeWire.pcm16Base64([2, -2]) == RealtimeWire.pcm16Base64([1, -1])) // out-of-range clamps
        let now = Date()
        try check(!RealtimeWire.shouldRotate(startedAt: now.addingTimeInterval(-60), now: now))
        try check(RealtimeWire.shouldRotate(startedAt: now.addingTimeInterval(-RealtimeWire.rotateAfterSeconds - 1), now: now))
    }
    @MainActor func deletingViewedMeetingLandsOnFreshSession() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let model = OverlayViewModel(root: root, restore: false)
        // The live session carries old chat (e.g. restored from a previous launch).
        model.transcript.appendFinal("Old live chat", speaker: "Speaker 1")
        try await model.flush()
        // A separate saved meeting is open in the viewer.
        var saved = Meeting.empty(); saved.meta.title = "Viewed meeting"; saved.context = "ctx"
        try await model.meetings.save(saved)
        model.viewMeeting(saved)
        for _ in 0..<100 where model.selected == nil { try await Task.sleep(for: .milliseconds(10)) }
        try check(model.selected?.id == saved.id)
        model.deleteMeeting(saved)
        for _ in 0..<200 where !model.transcript.lines.isEmpty || model.lastDeleted == nil { try await Task.sleep(for: .milliseconds(10)) }
        // Fresh empty meeting on screen — never the old live chat.
        try check(model.selected == nil)
        try check(model.transcript.lines.isEmpty)
        // The deleted meeting left the library; the old live chat is archived, not shown.
        try check(model.meetings.meetings.allSatisfy { $0.id != saved.id })
        try check(model.meetings.meetings.contains { $0.lines.contains { $0.text == "Old live chat" } })
        try await model.flush()
    }
    @MainActor func trashedMeetingStaysGoneAfterRelaunch() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let model = OverlayViewModel(root: root, restore: false)
        var meeting = Meeting.empty(); meeting.meta.title = "Doomed"
        try await model.meetings.save(meeting)
        model.deleteMeeting(meeting)
        for _ in 0..<100 where model.lastDeleted == nil { try await Task.sleep(for: .milliseconds(10)) }
        try check(model.meetings.meetings.allSatisfy { $0.id != meeting.id })
        // A relaunch (fresh store over the same root) must not resurrect it.
        let revived = OverlayViewModel(root: root, restore: true)
        for _ in 0..<100 where revived.restoring { try await Task.sleep(for: .milliseconds(10)) }
        try check(revived.meetings.meetings.allSatisfy { $0.id != meeting.id })
        // The file is kept in Kura's Trash for Undo — gone from the library, not shredded.
        try check(FileManager.default.fileExists(atPath: root.appendingPathComponent("Trash/\(meeting.id.uuidString).json").path))
    }
    func decisionAndFollowUpActions() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = RecordingProvider()
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { _ in provider })
        model.question = "Launch Friday"; model.captureDecision()
        try check(model.current.wrapUp.notes.contains("## Decisions") && model.current.wrapUp.notes.contains("- Launch Friday"))
        try check(model.current.lines.contains { $0.source == "decision" && $0.text == "Launch Friday" })
        try check(model.question.isEmpty)
        // A second decision joins the same section instead of adding a heading.
        model.question = "Ship the beta Monday"; model.captureDecision()
        try check(model.current.wrapUp.notes.contains("- Launch Friday\n- Ship the beta Monday"))
        try check(model.current.wrapUp.notes.components(separatedBy: "## Decisions").count == 2)
        model.assist(.followUps)
        for _ in 0..<100 where model.status == .streaming { try await Task.sleep(for: .milliseconds(10)) }
        try check(model.current.wrapUp.notes.contains("## Follow-up draft") && model.current.wrapUp.notes.contains(provider.response))
        try check(model.tab == .wrapUp)
        model.assist(.recap)
        for _ in 0..<100 where model.status == .streaming { try await Task.sleep(for: .milliseconds(10)) }
        try check(provider.messages.first?.content.contains("Briefly recap") == true)
        model.assist(.whatToSay)
        for _ in 0..<100 where model.status == .streaming { try await Task.sleep(for: .milliseconds(10)) }
        try check(provider.messages.first?.content.contains("Suggest a useful") == true)
        try await model.flush()
    }
    func usageParsingPerProvider() throws {
        // Anthropic: input on message_start (cache reads reported separately), output on message_delta.
        let start = AnthropicProvider.usage(from: Data(#"{"type":"message_start","message":{"usage":{"input_tokens":120,"cache_read_input_tokens":30,"output_tokens":1}}}"#.utf8))
        try check(start == LLMUsage(inputTokens: 120, outputTokens: 0, cachedInputTokens: 30))
        let delta = AnthropicProvider.usage(from: Data(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42}}"#.utf8))
        try check(delta == LLMUsage(inputTokens: 0, outputTokens: 42))
        try check(AnthropicProvider.usage(from: Data(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}"#.utf8)) == nil)
        // OpenAI Responses: cached tokens normalize out of the full-rate input count.
        let completed = OpenAIResponsesProvider.usage(Data(#"{"type":"response.completed","response":{"usage":{"input_tokens":100,"output_tokens":20,"input_tokens_details":{"cached_tokens":40}}}}"#.utf8))
        try check(completed == LLMUsage(inputTokens: 60, outputTokens: 20, cachedInputTokens: 40))
        try check(OpenAIResponsesProvider.usage(Data(#"{"type":"response.output_text.delta","delta":"Hi"}"#.utf8)) == nil)
        // OpenAI-compatible chat completions: usage chunk arrives with empty choices.
        let chat = OpenAICompatibleProvider.usage(from: Data(#"{"choices":[],"usage":{"prompt_tokens":50,"completion_tokens":10,"prompt_tokens_details":{"cached_tokens":5}}}"#.utf8))
        try check(chat == LLMUsage(inputTokens: 45, outputTokens: 10, cachedInputTokens: 5))
        try check(OpenAICompatibleProvider.usage(from: Data(#"{"choices":[{"delta":{"content":"Hi"}}]}"#.utf8)) == nil)
        // Ollama: eval counts on the final done line.
        let ollama = OllamaProvider.usage(from: Data(#"{"done":true,"prompt_eval_count":33,"eval_count":12}"#.utf8))
        try check(ollama == LLMUsage(inputTokens: 33, outputTokens: 12))
        try check(OllamaProvider.usage(from: Data(#"{"done":false,"message":{"content":"Hi"}}"#.utf8)) == nil)
        // Realtime: response.done usage with the audio/text split; cached normalizes out of text input.
        let realtime = RealtimeWire.usage(from: Data(#"{"type":"response.done","response":{"status":"completed","usage":{"total_tokens":500,"input_tokens":400,"output_tokens":100,"input_token_details":{"text_tokens":150,"audio_tokens":250,"cached_tokens":20},"output_token_details":{"text_tokens":100,"audio_tokens":0}}}}"#.utf8))
        try check(realtime == LLMUsage(inputTokens: 130, outputTokens: 100, cachedInputTokens: 20, audioInputTokens: 250, audioOutputTokens: 0))
        try check(RealtimeWire.usage(from: Data(#"{"type":"response.done","response":{"status":"failed"}}"#.utf8)) == nil)
    }
    func modelPricingAndCostMath() throws {
        let mini = ModelPricing.pricePerMTok(model: "gpt-5-mini")
        try check(mini?.input == 0.25 && mini?.output == 2.00 && mini?.cachedInput == 0.025)
        // Cached math: 600k fresh input + 400k cached + 1M output = 0.15 + 0.01 + 2.00.
        let cost = ModelPricing.cost(for: LLMUsage(inputTokens: 600_000, outputTokens: 1_000_000, cachedInputTokens: 400_000), model: "gpt-5-mini")
        try check(abs((cost ?? 0) - 2.16) < 0.0001)
        // Prefix specificity: gpt-5.5 must outrank gpt-5, claude-opus-4.5 outranks claude-opus-4.
        try check(ModelPricing.pricePerMTok(model: "gpt-5.5")?.output == 30.00)
        try check(ModelPricing.pricePerMTok(model: "gpt-5-nano")?.input == 0.05)
        try check(ModelPricing.pricePerMTok(model: "claude-opus-4.5")?.input == 5.00)
        try check(ModelPricing.pricePerMTok(model: "claude-opus-4")?.input == 15.00)
        // Unknown models are unpriced, not guessed.
        try check(ModelPricing.pricePerMTok(model: "llama3.2") == nil)
        try check(ModelPricing.cost(for: LLMUsage(inputTokens: 1, outputTokens: 1), model: "llama3.2") == nil)
        // Realtime audio/text split: 1M text in @0.60 + 1M text out @2.40 + 1M audio in @10 + 1M audio out @20.
        let realtimeCost = ModelPricing.cost(for: LLMUsage(inputTokens: 1_000_000, outputTokens: 1_000_000, audioInputTokens: 1_000_000, audioOutputTokens: 1_000_000), model: "gpt-realtime-mini")
        try check(abs((realtimeCost ?? 0) - 33.0) < 0.001)
        try check(ModelPricing.formatTokenCount(2100) == "2.1k" && ModelPricing.formatTokenCount(380) == "380")
        try check(ModelPricing.formatUSD(0.0042) == "0.0042" && ModelPricing.formatUSD(0.07) == "0.07")
    }
    @MainActor func answerMetaAndSpendRecorded() async throws {
        let defaults = UserDefaults.standard
        let keys = ["provider", "deepModelEnabled", "anthropicModel", "deepAnthropicModel"]
        let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer { for (key, value) in saved { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        defaults.set("Anthropic", forKey: "provider")
        defaults.set(false, forKey: "deepModelEnabled")
        defaults.set("claude-sonnet-4-5", forKey: "anthropicModel")
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = RecordingProvider()
        provider.usage = LLMUsage(inputTokens: 1000, outputTokens: 100)
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { _ in provider })
        model.question = "Price this answer"; model.send()
        for _ in 0..<100 where model.status == .streaming { try await Task.sleep(for: .milliseconds(10)) }
        let line = model.session.lines.last
        try check(line?.source == "assistant" && line?.isFinal == true)
        try check(line?.answerMeta?.model == "claude-sonnet-4-5")
        try check(line?.answerMeta?.inputTokens == 1000 && line?.answerMeta?.outputTokens == 100)
        // claude-sonnet-4: 1000 in @3.00 + 100 out @15.00 per 1M = $0.0045.
        try check(abs((line?.answerMeta?.costUSD ?? 0) - 0.0045) < 0.000001)
        try check(abs(model.session.aiSpendUSD - 0.0045) < 0.000001)
        try check(line?.answerMeta?.firstTokenSeconds != nil && line?.answerMeta?.totalSeconds != nil)
        // A provider without usage still completes: tokens/cost absent, timing present, spend untouched.
        provider.usage = nil
        model.question = "No usage here"; model.send()
        for _ in 0..<100 where model.status == .streaming { try await Task.sleep(for: .milliseconds(10)) }
        let plain = model.session.lines.last
        try check(plain?.text == provider.response && plain?.answerMeta != nil)
        try check(plain?.answerMeta?.inputTokens == nil && plain?.answerMeta?.costUSD == nil)
        try check(plain?.answerMeta?.totalSeconds != nil)
        try check(abs(model.session.aiSpendUSD - 0.0045) < 0.000001)
        // The spend total survives persistence.
        try await model.flush()
        let savedDraft = try await model.meetings.repository.draft()
        try check(abs((savedDraft?.aiSpendUSD ?? 0) - 0.0045) < 0.000001)
    }
    @MainActor func wrapUpUsageAddsToSpend() async throws {
        let defaults = UserDefaults.standard
        let keys = ["provider", "deepModelEnabled", "anthropicModel", "deepAnthropicModel"]
        let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer { for (key, value) in saved { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        defaults.set("Anthropic", forKey: "provider")
        defaults.set(false, forKey: "deepModelEnabled")
        defaults.set("claude-sonnet-4-5", forKey: "anthropicModel")
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = RecordingProvider()
        provider.response = "## Summary\n\nLaunch confirmed for Friday."
        provider.usage = LLMUsage(inputTokens: 1000, outputTokens: 100)
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { _ in provider })
        model.transcript.appendFinal("Launch Friday.", speaker: "Alex")
        model.generateWrapUp()
        for _ in 0..<100 where model.status == .streaming { try await Task.sleep(for: .milliseconds(10)) }
        try check(model.lastError.isEmpty)
        try check(abs(model.session.aiSpendUSD - 0.0045) < 0.000001)
        try await model.flush()
    }
    func answerMetaCodableCompatibility() throws {
        var line = TranscriptLine(speaker: "Kura", text: "Hi", source: "assistant")
        line.answerMeta = AnswerMeta(model: "gpt-5-mini", inputTokens: 10, outputTokens: 5, costUSD: 0.001, firstTokenSeconds: 0.4, totalSeconds: 1.2)
        let roundtrip = try JSONDecoder().decode(TranscriptLine.self, from: JSONEncoder().encode(line))
        try check(roundtrip == line)
        // Lines saved before answerMeta existed decode with nil.
        let old = try JSONDecoder().decode(TranscriptLine.self, from: Data(#"{"speaker":"Kura","text":"Hi","isFinal":true,"source":"assistant"}"#.utf8))
        try check(old.answerMeta == nil)
        // Partial metadata (unpriced model: tokens but no cost) round-trips too.
        var unpriced = TranscriptLine(speaker: "Kura", text: "Hi", source: "assistant")
        unpriced.answerMeta = AnswerMeta(model: "llama3.2", inputTokens: 33, outputTokens: 12, costUSD: nil, firstTokenSeconds: nil, totalSeconds: 2.0)
        try check(try JSONDecoder().decode(TranscriptLine.self, from: JSONEncoder().encode(unpriced)) == unpriced)
        // Meeting.aiSpendUSD round-trips and defaults to 0 for old files.
        var meeting = Meeting.empty(); meeting.aiSpendUSD = 0.07
        let restored = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting))
        try check(restored == meeting && restored.aiSpendUSD == 0.07)
        let oldMeeting = try JSONDecoder().decode(Meeting.self, from: Data("{\"meta\":{\"id\":\"\(UUID())\",\"title\":\"Old\",\"date\":0}}".utf8))
        try check(oldMeeting.aiSpendUSD == 0)
    }
}

private enum CheckFailure: Error { case failed(String) }
private func check(_ condition: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    if !condition { throw CheckFailure.failed("\(file):\(line)") }
}
