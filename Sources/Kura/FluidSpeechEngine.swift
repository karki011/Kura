// FluidSpeechEngine — fully on-device transcription with live speaker labels via FluidAudio
// (Parakeet EOU 120M streaming ASR + Sortformer v2.1 streaming diarization, CoreML on the ANE).
// Replaces the Python whisper.cpp/pyannote pipeline: models download from Hugging Face on
// first use and run offline afterwards. Speaker indices are Sortformer's session-stable slots.
import AVFoundation
import Foundation

/// Which engine transcribes the system-audio tap. Persisted in UserDefaults as
/// "transcriptionBackend"; the retired Python pipeline's "local" value now maps to `.fluid`.
enum TranscriptionEngine: String {
    case apple, fluid
    static var saved: TranscriptionEngine {
        let raw = UserDefaults.standard.string(forKey: "transcriptionBackend") ?? "apple"
        return raw == "apple" ? .apple : .fluid
    }
}

/// AVAudioPCMBuffer is not Sendable; the tap callback hands each buffer off exactly once.
struct SendableAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

#if canImport(FluidAudio)
import FluidAudio

actor FluidSpeechEngine {
    static let shared = FluidSpeechEngine()

    private static let chunkSize: StreamingChunkSize = .ms320
    private static let diarizerConfig: SortformerConfig = .balancedV2_1
    private let eouDebounceMs = 1280

    private var asr: StreamingEouAsrManager?
    private var diarizerModels: SortformerModels?
    private var diarizer: SortformerDiarizer?

    private var prepareRunning = false
    private var prepareWaiters: [CheckedContinuation<Void, Error>] = []
    private var sessionActive = false
    private var failed = false
    private var emittedTranscript = ""
    private var emittedTokenCount = 0
    private var utteranceStartMs = 0
    private var pending: [Float] = []
    private var pendingRate: Double = 16000
    private var chunksProcessed = 0

    private var onSegment: (@Sendable (SpeakerSegment) -> Void)?
    private var onPartial: (@Sendable (String) -> Void)?
    private var onError: (@Sendable (String) -> Void)?

    func setHandlers(onSegment: (@Sendable (SpeakerSegment) -> Void)?,
                     onPartial: (@Sendable (String) -> Void)?,
                     onError: (@Sendable (String) -> Void)?) {
        self.onSegment = onSegment; self.onPartial = onPartial; self.onError = onError
    }

    /// Downloads (first run only) and loads both model sets. Concurrent callers wait for the
    /// same prepare. `progress` receives (fraction 0…1, stage label) from download threads.
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        if asr != nil, diarizerModels != nil { progress(1, "On-device speech ready"); return }
        if prepareRunning {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in prepareWaiters.append(cont) }
            return
        }
        prepareRunning = true
        do {
            progress(0.02, "Preparing speech recognition")
            let manager = StreamingEouAsrManager(chunkSize: Self.chunkSize, eouDebounceMs: eouDebounceMs)
            try await manager.loadModels(to: nil, configuration: nil) { p in
                progress(0.02 + p.fractionCompleted * 0.48, "Downloading speech recognition")
            }
            progress(0.5, "Preparing speaker separation")
            let models = try await SortformerModels.loadFromHuggingFace(config: Self.diarizerConfig) { p in
                progress(0.5 + p.fractionCompleted * 0.48, "Downloading speaker separation")
            }
            asr = manager; diarizerModels = models
            prepareRunning = false
            let waiters = prepareWaiters; prepareWaiters = []
            for waiter in waiters { waiter.resume() }
            progress(1, "On-device speech ready")
        } catch {
            prepareRunning = false
            let waiters = prepareWaiters; prepareWaiters = []
            for waiter in waiters { waiter.resume(throwing: error) }
            throw error
        }
    }

    /// Starts a capture session. Requires a successful `prepare` first.
    func startSession() async throws {
        NSLog("[fluid] session start requested")
        guard let asr, let diarizerModels else {
            throw KuraError.message("On-device speech models are not ready yet.")
        }
        await asr.reset()
        await asr.setEouCallback { [weak self] transcript in
            guard let self else { return }
            Task { await self.utteranceEnded(accumulated: transcript) }
        }
        await asr.setPartialCallback { [weak self] transcript in
            guard let self else { return }
            Task { await self.partialUpdated(transcript) }
        }
        let diarizer = SortformerDiarizer(config: Self.diarizerConfig)
        diarizer.initialize(models: diarizerModels)
        self.diarizer = diarizer
        emittedTranscript = ""; utteranceStartMs = 0; pending = []; emittedTokenCount = 0
        failed = false; sessionActive = true; chunksProcessed = 0
        NSLog("[fluid] session running")
    }

    /// Feed one tap buffer. Both engines resample internally; audio accumulates into
    /// half-second chunks to keep resample and inference calls at a steady cadence.
    func append(_ audio: SendableAudioBuffer) async {
        guard sessionActive, !failed else { return }
        guard let samples = Self.monoSamples(audio.buffer) else { return }
        pendingRate = audio.buffer.format.sampleRate
        pending.append(contentsOf: samples)
        // If inference ever falls behind realtime, drop the oldest audio instead of growing memory.
        let cap = Int(pendingRate * 30)
        if pending.count > cap { pending.removeFirst(pending.count - cap) }
        let chunkTarget = Int(pendingRate * 0.5)
        while pending.count >= chunkTarget {
            let chunk = Array(pending.prefix(chunkTarget))
            pending.removeFirst(chunkTarget)
            await processChunk(chunk, rate: pendingRate)
        }
    }

    /// Flushes the tail of the audio, emits the final utterance, and releases session state.
    /// Loaded models stay warm for the next session.
    func finishSession() async {
        guard sessionActive || diarizer != nil else { return }
        sessionActive = false
        if !pending.isEmpty {
            let tail = pending; pending = []
            await processChunk(tail, rate: pendingRate)
        }
        if let diarizer { _ = try? diarizer.finalizeSession() }
        if let asr {
            // finish() clears the accumulated token timestamps; snapshot them first.
            let timestamps = await asr.getTokenTimestampsMs()
            if let full = try? await asr.finish() {
                await emit(accumulated: full, tokenTimestamps: timestamps)
                await asr.reset()
            }
        }
        diarizer = nil
        failed = false
    }

    private func processChunk(_ samples: [Float], rate: Double) async {
        guard !failed else { return }
        chunksProcessed += 1
        if chunksProcessed == 1 { NSLog("[fluid] first chunk processed (%d samples @ %.0f Hz)", samples.count, rate) }
        if let diarizer {
            do { _ = try diarizer.process(samples: samples, sourceSampleRate: rate) }
            catch { fail("Speaker separation failed: \(error.localizedDescription)"); return }
        }
        if let asr, let pcm = Self.monoBuffer(samples, rate: rate) {
            do {
                try await asr.appendAudio(pcm)
                try await asr.processBufferedAudio()
            } catch { fail("On-device transcription failed: \(error.localizedDescription)") }
        }
    }

    private func fail(_ message: String) {
        guard !failed else { return }
        NSLog("[fluid] error: %@", message)
        failed = true; sessionActive = false
        onError?(message)
    }

    /// The EOU callback carries the whole session's accumulated transcript, so the new
    /// utterance is the diff against what was already emitted. Utterance bounds come from
    /// the ASR's per-token timestamps (relative to session start), which are far more
    /// accurate than the EOU confirmation time (that trails speech by the debounce window).
    private func utteranceEnded(accumulated: String) async {
        guard sessionActive, !failed else { return }
        await emit(accumulated: accumulated)
    }

    private func emit(accumulated: String, tokenTimestamps: [Int]? = nil) async {
        let fresh = accumulated.hasPrefix(emittedTranscript) ? String(accumulated.dropFirst(emittedTranscript.count)) : accumulated
        let text = fresh.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { emittedTranscript = accumulated }
        guard !text.isEmpty else { return }
        var startMs = utteranceStartMs
        var endMs = utteranceStartMs
        if let asr {
            let timestamps: [Int]
            if let tokenTimestamps { timestamps = tokenTimestamps }
            else { timestamps = await asr.getTokenTimestampsMs() }
            if timestamps.count > emittedTokenCount {
                let newTokens = timestamps[emittedTokenCount...]
                startMs = newTokens.first ?? startMs
                endMs = (newTokens.last ?? startMs) + Self.chunkSize.durationMs
            }
            emittedTokenCount = timestamps.count
        }
        utteranceStartMs = endMs
        let startS = Double(startMs) / 1000
        let speaker = dominantSpeaker(start: startS, end: Double(endMs) / 1000 + 0.2)
        NSLog("[fluid] utterance committed speaker=%d start=%.1fs: %@", speaker, startS, text)
        onSegment?(SpeakerSegment(speaker: speaker, text: text, start: startS))
    }

    private func partialUpdated(_ accumulated: String) {
        guard sessionActive, !failed, accumulated.hasPrefix(emittedTranscript) else { return }
        let tail = String(accumulated.dropFirst(emittedTranscript.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { onPartial?(tail) }
    }

    /// Majority speaker over the utterance window across finalized + tentative segments.
    /// Returns -1 ("Unknown speaker") when diarization has nothing for the window.
    private func dominantSpeaker(start: Double, end: Double) -> Int {
        guard let diarizer else { return -1 }
        var bestIndex = -1, bestOverlap = 0.0
        for (index, speaker) in diarizer.timeline.speakers {
            var overlap = 0.0
            for segment in speaker.finalizedSegments + speaker.tentativeSegments {
                let s = max(start, Double(segment.startTime)), e = min(end, Double(segment.endTime))
                if e > s { overlap += e - s }
            }
            if overlap > bestOverlap { bestIndex = index; bestOverlap = overlap }
        }
        return bestIndex
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

#else
// check.sh compiles the sources with plain swiftc (no SPM dependencies). This stub keeps that
// build green; the packaged app always builds through SPM and gets the real engine above.
actor FluidSpeechEngine {
    static let shared = FluidSpeechEngine()
    private static let unavailable = "On-device speech is unavailable in this build."
    func setHandlers(onSegment: (@Sendable (SpeakerSegment) -> Void)?,
                     onPartial: (@Sendable (String) -> Void)?,
                     onError: (@Sendable (String) -> Void)?) {}
    func prepare(progress: @Sendable (Double, String) -> Void) async throws {
        throw KuraError.message(Self.unavailable)
    }
    func startSession() async throws { throw KuraError.message(Self.unavailable) }
    func append(_ audio: SendableAudioBuffer) async {}
    func finishSession() async {}
}
#endif
