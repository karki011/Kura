// RealtimeSpeechEngine — cloud transcription + answers via the OpenAI Realtime API
// (GA interface, WebSocket). The model hears the meeting audio directly, so auto answers
// are immune to transcription garbling. semantic_vad commits turns without auto-responses
// (create_response: false); answers are triggered manually with response.create.
// Sessions cap at 60 minutes, so the socket rotates proactively with a context handoff.
// Pure Foundation/AVFoundation: compiles in both the SPM build and the check.sh swiftc build.
import AVFoundation
import Foundation

/// Wire protocol for the OpenAI Realtime API (GA). Pure functions so the check build
/// can verify payloads and event parsing without a network.
enum RealtimeWire {
    static let endpoint = "wss://api.openai.com/v1/realtime"
    static let model = "gpt-realtime-mini"
    static let transcriptionModel = "gpt-4o-mini-transcribe"
    static let sampleRate: Double = 24000
    /// Hard server-side cap; the engine rotates well before it.
    static let sessionLimitSeconds: TimeInterval = 60 * 60
    static let rotateAfterSeconds: TimeInterval = 55 * 60

    static func sessionInstructions(context: String) -> String {
        var instructions = systemPrompt
        instructions += "\nYou hear the live meeting audio directly. Answer only from what was actually said in the audio or the meeting context below; if something was never stated, say so plainly instead of guessing."
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { instructions += "\n\nMeeting context:\n\(trimmed)" }
        return instructions
    }

    /// Per-response guardrail: hallucinated times/names/decisions are worse than no
    /// answer, so "not stated" must be an explicit, easy way out.
    static func answerInstructions(question: String) -> String {
        "Answer this spoken question in a sentence or two, using only what was actually said in the meeting audio or the provided meeting context. If the answer was never stated, say plainly that it wasn't mentioned in the meeting — never invent times, dates, names, numbers, or decisions. Question: \(question)"
    }

    static func sessionUpdate(instructions: String) -> [String: Any] {
        [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "output_modalities": ["text"],
                "instructions": instructions,
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": Int(sampleRate)],
                        "transcription": ["model": transcriptionModel],
                        "turn_detection": [
                            "type": "semantic_vad",
                            "create_response": false,
                            "interrupt_response": false,
                        ],
                    ],
                ],
            ] as [String: Any],
        ]
    }

    static func audioAppend(base64: String) -> [String: Any] {
        ["type": "input_audio_buffer.append", "audio": base64]
    }

    static func responseCreate(instructions: String) -> [String: Any] {
        [
            "type": "response.create",
            "response": [
                "instructions": instructions,
                "output_modalities": ["text"],
                "metadata": ["kura": "auto-answer"],
            ] as [String: Any],
        ]
    }

    /// Float32 [-1, 1] → little-endian PCM16 → base64, matching the API's floatTo16BitPCM.
    static func pcm16Base64(_ samples: [Float]) -> String {
        var data = Data()
        data.reserveCapacity(samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var value = Int16(clamped < 0 ? clamped * Float(0x8000) : clamped * Float(0x7FFF)).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data.base64EncodedString()
    }

    /// `response.done` carries the session's billable usage with an audio/text split.
    /// cached_tokens is a subset of input_tokens (OpenAI convention), so text input is
    /// normalized to the full-rate count. Cached audio tokens are folded into the single
    /// cached figure and priced at the cached text rate — close enough for an estimate.
    static func usage(from data: Data) -> LLMUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "response.done",
              let usage = (object["response"] as? [String: Any])?["usage"] as? [String: Any] else { return nil }
        let totalIn = usage["input_tokens"] as? Int ?? 0
        let totalOut = usage["output_tokens"] as? Int ?? 0
        guard totalIn > 0 || totalOut > 0 else { return nil }
        let inDetails = usage["input_token_details"] as? [String: Any]
        let outDetails = usage["output_token_details"] as? [String: Any]
        let audioIn = inDetails?["audio_tokens"] as? Int ?? 0
        let audioOut = outDetails?["audio_tokens"] as? Int ?? 0
        let cached = inDetails?["cached_tokens"] as? Int
        return LLMUsage(inputTokens: max(0, totalIn - audioIn - (cached ?? 0)),
                        outputTokens: max(0, totalOut - audioOut),
                        cachedInputTokens: cached,
                        audioInputTokens: audioIn,
                        audioOutputTokens: audioOut)
    }

    static func shouldRotate(startedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(startedAt) >= rotateAfterSeconds
    }

    enum Event: Equatable {
        case sessionCreated
        case sessionUpdated
        case transcriptDelta(itemID: String, delta: String)
        case transcriptCompleted(String)
        case transcriptFailed(String)
        case textDelta(String)
        case textDone(String)
        case responseDone(status: String?)
        case error(String)
        case ignored(String)
    }

    static func parse(_ data: Data) -> Event {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return .ignored("") }
        switch type {
        case "session.created":
            return .sessionCreated
        case "session.updated":
            return .sessionUpdated
        case "conversation.item.input_audio_transcription.delta":
            return .transcriptDelta(itemID: object["item_id"] as? String ?? "",
                                    delta: object["delta"] as? String ?? "")
        case "conversation.item.input_audio_transcription.completed":
            return .transcriptCompleted(object["transcript"] as? String ?? "")
        case "conversation.item.input_audio_transcription.failed":
            let error = object["error"] as? [String: Any]
            return .transcriptFailed(error?["message"] as? String ?? "input transcription failed")
        case "response.output_text.delta":
            return .textDelta(object["delta"] as? String ?? "")
        case "response.output_text.done":
            return .textDone(object["text"] as? String ?? "")
        case "response.done":
            let response = object["response"] as? [String: Any]
            return .responseDone(status: response?["status"] as? String)
        case "error", "invalid_request_error":
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return .error(message)
            }
            return .error(object["message"] as? String ?? "unknown realtime error")
        default:
            return .ignored(type)
        }
    }
}

actor RealtimeSpeechEngine {
    static let shared = RealtimeSpeechEngine()

    private static let missingKey = "OpenAI Realtime needs an OpenAI API key. Add one in Settings → AI setup under the OpenAI provider, then start Listen again."

    /// One WebSocket session. Mutated only on the actor (event handling hops there).
    private final class Socket: @unchecked Sendable {
        let task: URLSessionWebSocketTask
        let session: URLSession
        let instructions: String
        var receiveTask: Task<Void, Never>?
        init(task: URLSessionWebSocketTask, session: URLSession, instructions: String) {
            self.task = task; self.session = session; self.instructions = instructions
        }
    }

    /// Guards a connect continuation against double-resume (server event vs. timeout vs. drop).
    private final class PendingConnect: @unchecked Sendable {
        let socket: Socket
        var continuation: CheckedContinuation<Void, Error>?
        var done = false
        init(socket: Socket) { self.socket = socket }
        func resume(_ result: Result<Void, Error>) {
            guard !done, let continuation else { return }
            done = true; self.continuation = nil
            continuation.resume(with: result)
        }
    }

    private var apiKey: String?
    private var currentSocket: Socket?
    private var pendingConnect: PendingConnect?
    private var active = false
    private var failed = false
    private var rotating = false
    private var reconnectUsed = false
    private var rotationTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    /// Base64 PCM16 chunks buffered while a rotation connect is in flight.
    private var pendingChunks: [String] = []
    private var contextProvider: (@Sendable () async -> String)?
    private var converter: AVAudioConverter?
    private var converterRate: Double = 0
    private var pendingSamples: [Float] = []
    private var audioSeconds: Double = 0
    private var lastSegmentStart: Double = 0
    private var partialItemID = ""
    private var partialText = ""
    private var answerContinuation: AsyncThrowingStream<String, Error>.Continuation?
    private var answerUsageHandler: (@Sendable (LLMUsage) -> Void)?

    private var onSegment: (@Sendable (SpeakerSegment) -> Void)?
    private var onPartial: (@Sendable (String) -> Void)?
    private var onError: (@Sendable (String) -> Void)?

    func setHandlers(onSegment: (@Sendable (SpeakerSegment) -> Void)?,
                     onPartial: (@Sendable (String) -> Void)?,
                     onError: (@Sendable (String) -> Void)?) {
        self.onSegment = onSegment; self.onPartial = onPartial; self.onError = onError
    }

    /// Light compared to the on-device engines: only verifies the OpenAI key exists.
    /// Keychain reads can block on a macOS access prompt — never on the main thread,
    /// which is why this lives on the actor.
    func prepare() async throws {
        if let apiKey, !apiKey.isEmpty { return }
        guard let key = Keychain.get(account: "openai-direct"), !key.isEmpty else {
            throw KuraError.message(Self.missingKey)
        }
        apiKey = key
    }

    /// Starts a capture session. `contextProvider` supplies the meeting background plus a
    /// rolling transcript tail; it is re-queried on every rotation so the handoff session
    /// inherits what was discussed. Requires a successful `prepare` first.
    func startSession(contextProvider: @escaping @Sendable () async -> String) async throws {
        guard !active else { return }
        guard let apiKey, !apiKey.isEmpty else { throw KuraError.message(Self.missingKey) }
        self.contextProvider = contextProvider
        NSLog("[realtime] session start requested")
        let context = await contextProvider()
        let socket = try await openSocket(instructions: RealtimeWire.sessionInstructions(context: context))
        currentSocket = socket
        active = true; failed = false; reconnectUsed = false; rotating = false
        audioSeconds = 0; lastSegmentStart = 0; partialItemID = ""; partialText = ""
        pendingSamples = []; pendingChunks = []
        scheduleRotation()
        startPing()
        NSLog("[realtime] session running")
    }

    /// Feed one tap buffer. Audio is resampled to 24kHz mono PCM16 and streamed in
    /// 100ms append events; during rotation it queues for the new session instead,
    /// so no audio is lost and none is double-transcribed.
    func append(_ audio: SendableAudioBuffer) async {
        guard active, !failed else { return }
        guard let samples = Self.monoSamples(audio.buffer),
              let resampled = resample(samples, from: audio.buffer.format.sampleRate) else { return }
        pendingSamples.append(contentsOf: resampled)
        // If the network stalls, drop the oldest audio instead of growing memory.
        let cap = Int(RealtimeWire.sampleRate * 30)
        if pendingSamples.count > cap { pendingSamples.removeFirst(pendingSamples.count - cap) }
        let chunkFrames = Int(RealtimeWire.sampleRate / 10)
        while pendingSamples.count >= chunkFrames {
            let chunk = Array(pendingSamples.prefix(chunkFrames))
            pendingSamples.removeFirst(chunkFrames)
            audioSeconds += Double(chunkFrames) / RealtimeWire.sampleRate
            let base64 = RealtimeWire.pcm16Base64(chunk)
            if rotating { pendingChunks.append(base64) }
            else { send(RealtimeWire.audioAppend(base64: base64)) }
        }
    }

    /// Commits any in-flight audio, waits briefly for the final transcription events,
    /// then closes the session. Key and handlers stay warm for the next session.
    func finishSession() async {
        guard active || currentSocket != nil else { return }
        rotationTask?.cancel(); rotationTask = nil
        pingTask?.cancel(); pingTask = nil
        if let socket = currentSocket {
            if active, !failed {
                send(["type": "input_audio_buffer.commit"], on: socket)
                try? await Task.sleep(for: .milliseconds(1500))
            }
            socket.receiveTask?.cancel()
            socket.task.cancel(with: .normalClosure, reason: nil)
            socket.session.invalidateAndCancel()
            currentSocket = nil
        }
        active = false; rotating = false; failed = false
        answerContinuation?.finish(); answerContinuation = nil; answerUsageHandler = nil
        pendingSamples = []; pendingChunks = []
        NSLog("[realtime] session finished")
    }

    /// Streams an answer to a spoken question from the model that heard the meeting.
    /// One answer at a time: a newer question cancels the in-flight response.
    /// `onUsage` fires once with the `response.done` token counts before the stream ends.
    nonisolated func respond(to question: String, onUsage: (@Sendable (LLMUsage) -> Void)? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { await self.beginAnswer(question: question, onUsage: onUsage, continuation: continuation) }
        }
    }

    private func beginAnswer(question: String, onUsage: (@Sendable (LLMUsage) -> Void)?, continuation: AsyncThrowingStream<String, Error>.Continuation) {
        guard active, !failed, let socket = currentSocket else {
            continuation.finish(throwing: KuraError.message("OpenAI Realtime is not connected. Start Listen to enable live answers."))
            return
        }
        if let previous = answerContinuation {
            send(["type": "response.cancel"], on: socket)
            previous.finish(throwing: CancellationError())
        }
        answerContinuation = continuation
        answerUsageHandler = onUsage
        send(RealtimeWire.responseCreate(instructions: RealtimeWire.answerInstructions(question: question)), on: socket)
    }

    // MARK: Socket lifecycle

    private func openSocket(instructions: String) async throws -> Socket {
        guard let apiKey else { throw KuraError.message(Self.missingKey) }
        var request = URLRequest(url: URL(string: "\(RealtimeWire.endpoint)?model=\(RealtimeWire.model)")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .default)
        let socket = Socket(task: session.webSocketTask(with: request), session: session, instructions: instructions)
        socket.task.maximumMessageSize = 8 * 1024 * 1024
        socket.task.resume()
        socket.receiveTask = Task { [weak self] in
            do {
                while true {
                    let message = try await socket.task.receive()
                    guard let self else { return }
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: continue
                    }
                    await self.handle(data)
                }
            } catch {
                guard let self else { return }
                await self.socketEnded(socket, error: error)
            }
        }
        let pending = PendingConnect(socket: socket)
        pendingConnect = pending
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            await self?.connectTimedOut(pending)
        }
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                pending.continuation = cont
            }
        } catch {
            socket.receiveTask?.cancel()
            socket.task.cancel(with: .normalClosure, reason: nil)
            socket.session.invalidateAndCancel()
            if pendingConnect?.socket === socket { pendingConnect = nil }
            throw error
        }
        if pendingConnect?.socket === socket { pendingConnect = nil }
        return socket
    }

    private func connectTimedOut(_ pending: PendingConnect) {
        pending.resume(.failure(KuraError.message("OpenAI Realtime session did not become ready.")))
    }

    private func handle(_ data: Data) {
        switch RealtimeWire.parse(data) {
        case .sessionCreated:
            if let socket = pendingConnect?.socket ?? currentSocket {
                send(RealtimeWire.sessionUpdate(instructions: socket.instructions), on: socket)
            }
        case .sessionUpdated:
            pendingConnect?.resume(.success(()))
        case .transcriptDelta(let itemID, let delta):
            guard active, !failed, !delta.isEmpty else { return }
            if partialItemID != itemID { partialItemID = itemID; partialText = "" }
            partialText += delta
            onPartial?(partialText)
        case .transcriptCompleted(let transcript):
            guard active, !failed else { return }
            let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            partialItemID = ""; partialText = ""
            guard !text.isEmpty else { return }
            // The API reports no utterance timing; approximate start from the end of the
            // previous segment — close enough for transcript timestamps.
            let start = min(lastSegmentStart, audioSeconds)
            lastSegmentStart = audioSeconds
            NSLog("[realtime] utterance committed: %@", text)
            onSegment?(SpeakerSegment(speaker: -1, text: text, start: start))
        case .transcriptFailed(let message):
            // Transcription is a side service; the model still heard the audio and can answer.
            NSLog("[realtime] input transcription failed: %@", message)
        case .textDelta(let delta):
            answerContinuation?.yield(delta)
        case .textDone:
            break // response.done closes the stream
        case .responseDone(let status):
            guard let continuation = answerContinuation else { return }
            let onUsage = answerUsageHandler
            answerContinuation = nil; answerUsageHandler = nil
            if status == "failed" {
                continuation.finish(throwing: KuraError.message("OpenAI Realtime answer failed."))
            } else {
                if let usage = RealtimeWire.usage(from: data) { onUsage?(usage) }
                continuation.finish()
            }
        case .error(let message):
            if let pending = pendingConnect {
                pending.resume(.failure(KuraError.message(message)))
            } else if let continuation = answerContinuation {
                answerContinuation = nil; answerUsageHandler = nil
                NSLog("[realtime] server error during answer: %@", message)
                continuation.finish(throwing: KuraError.message(message))
            } else {
                NSLog("[realtime] server error: %@", message)
            }
        case .ignored:
            break
        }
    }

    private func socketEnded(_ socket: Socket, error: Error) {
        if pendingConnect?.socket === socket {
            pendingConnect?.resume(.failure(error)); pendingConnect = nil
            return
        }
        guard socket === currentSocket, active, !failed else { return }
        // A drop mid-rotation is handled by the rotation's own failure path.
        guard !rotating else { return }
        if !reconnectUsed {
            reconnectUsed = true
            NSLog("[realtime] connection dropped (%@); reconnecting once", error.localizedDescription)
            Task { await self.rotate() }
        } else {
            fail("OpenAI Realtime connection lost: \(error.localizedDescription)")
        }
    }

    // MARK: Rotation (60-minute session cap)

    private func scheduleRotation() {
        rotationTask?.cancel()
        rotationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(RealtimeWire.rotateAfterSeconds)) } catch { return }
            await self?.rotate()
        }
    }

    /// Opens a fresh session before the 60-minute cap and swaps it in. The old socket gets
    /// a commit for its in-flight turn plus a grace period for the last transcription
    /// events; audio appended during the connect queues for the new session, so every
    /// chunk is transcribed exactly once.
    private func rotate() async {
        guard active, !failed, !rotating, let old = currentSocket else { return }
        rotating = true
        NSLog("[realtime] rotating session before the 60-minute cap")
        send(["type": "input_audio_buffer.commit"], on: old)
        do {
            let context = await contextProvider?() ?? ""
            let socket = try await openSocket(instructions: RealtimeWire.sessionInstructions(context: context))
            currentSocket = socket
            scheduleRotation()
            let queued = pendingChunks; pendingChunks = []
            for chunk in queued { send(RealtimeWire.audioAppend(base64: chunk), on: socket) }
            rotating = false
            NSLog("[realtime] rotation complete")
            Task {
                try? await Task.sleep(for: .seconds(5))
                old.receiveTask?.cancel()
                old.task.cancel(with: .normalClosure, reason: nil)
                old.session.invalidateAndCancel()
            }
        } catch {
            rotating = false; pendingChunks = []
            fail("OpenAI Realtime session rotation failed: \(error.localizedDescription)")
        }
    }

    private func startPing() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                await self?.pingCurrent()
            }
        }
    }

    private func pingCurrent() {
        currentSocket?.task.sendPing { error in
            if let error { NSLog("[realtime] ping failed: %@", error.localizedDescription) }
        }
    }

    private func send(_ event: [String: Any], on socket: Socket? = nil) {
        guard let socket = socket ?? currentSocket,
              let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.task.send(.string(text)) { error in
            if let error { NSLog("[realtime] send failed: %@", error.localizedDescription) }
        }
    }

    private func fail(_ message: String) {
        guard !failed else { return }
        NSLog("[realtime] error: %@", message)
        failed = true; active = false
        answerContinuation?.finish(throwing: KuraError.message(message)); answerContinuation = nil; answerUsageHandler = nil
        onError?(message)
    }

    // MARK: Audio conversion

    private func resample(_ samples: [Float], from rate: Double) -> [Float]? {
        if rate == RealtimeWire.sampleRate { return samples }
        guard rate > 0 else { return nil }
        if converter == nil || converterRate != rate {
            guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
                  let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: RealtimeWire.sampleRate, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: input, to: output) else { return nil }
            self.converter = converter; converterRate = rate
        }
        guard let converter,
              let input = Self.monoBuffer(samples, rate: rate),
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                            frameCapacity: AVAudioFrameCount(Double(samples.count) * RealtimeWire.sampleRate / rate + 256)) else { return nil }
        var error: NSError?
        var consumed = false
        let status = converter.convert(to: output, error: &error) { _, statusPtr in
            // Streaming pattern: hand the buffer over once, keep the converter's state
            // alive across calls so chunk seams don't drift.
            if consumed { statusPtr.pointee = .noDataNow; return nil }
            consumed = true; statusPtr.pointee = .haveData; return input
        }
        guard status != .error, error == nil else { return nil }
        let count = Int(output.frameLength)
        guard count > 0, let channel = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: count))
    }

    private static func monoSamples(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channels = buffer.floatChannelData else { return nil }
        let count = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
        guard count > 0, channelCount > 0 else { return nil }
        var mono = [Float](repeating: 0, count: count)
        for frame in 0..<count {
            var value: Float = 0
            for channel in 0..<channelCount {
                value += buffer.format.isInterleaved ? channels[0][frame * channelCount + channel] : channels[channel][frame]
            }
            mono[frame] = value / Float(channelCount)
        }
        return mono
    }

    private static func monoBuffer(_ samples: [Float], rate: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        buffer.floatChannelData?[0].update(from: samples, count: samples.count)
        return buffer
    }
}
