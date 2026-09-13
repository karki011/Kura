// FluidSpeechEngine — fully on-device transcription with live speaker labels via FluidAudio
// (Parakeet EOU 120M streaming ASR on the ANE + LS-EEND or Sortformer streaming diarization).
// Replaces the Python whisper.cpp/pyannote pipeline: models download from Hugging Face on
// first use and run offline afterwards. Speaker indices are session-stable 0-based slots.
// Committed utterances are optionally re-checked against user-supplied names/jargon
// ("customVocabulary") via FluidAudio's CTC vocabulary rescoring.
import AVFoundation
import Foundation

/// Which engine transcribes the system-audio tap. Persisted in UserDefaults as
/// "transcriptionBackend"; the retired Python pipeline's "local" value now maps to `.fluid`.
enum TranscriptionEngine: String {
    case apple, fluid, realtime
    static var saved: TranscriptionEngine {
        let raw = UserDefaults.standard.string(forKey: "transcriptionBackend") ?? "apple"
        if raw == "local" { return .fluid }
        return TranscriptionEngine(rawValue: raw) ?? .apple
    }
}

/// Which streaming diarizer labels speakers. Persisted as "diarizerBackend".
/// LS-EEND handles up to 10 speakers and is FluidAudio's default online diarizer;
/// Sortformer is capped at 4 but keeps identities steadier within a session.
enum DiarizerBackend: String {
    case eend, sortformer
    static var saved: DiarizerBackend {
        DiarizerBackend(rawValue: UserDefaults.standard.string(forKey: "diarizerBackend") ?? "") ?? .eend
    }
}

/// User-supplied terms (names, products, jargon) that on-device transcription
/// re-checks committed utterances against. Persisted raw as a String in
/// UserDefaults; parsed here, outside the FluidAudio gate, so the plain-swiftc
/// check build can test the parsing.
enum CustomVocabulary {
    static let defaultsKey = "customVocabulary"

    /// Splits on newlines/commas, trims, drops empties, dedupes case-insensitively
    /// (first occurrence's spelling wins).
    static func parseTerms(_ raw: String) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for piece in raw.split(whereSeparator: { $0.isNewline || $0 == "," }) {
            let term = piece.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
        }
        return terms
    }

    static var saved: [String] {
        parseTerms(UserDefaults.standard.string(forKey: defaultsKey) ?? "")
    }
}

/// Word-level seam repair for FluidSpeechEngine's epoch-replay preroll: when an
/// utterance runs right up to the ASR reset, the replayed preroll re-decodes
/// speech the previous epoch already committed; drop that repeated prefix.
/// Pure and FluidAudio-free so the plain-swiftc check build can test it.
enum TranscriptSeam {
    /// Returns `text` with any leading words removed that repeat the trailing
    /// words of `previous`. The seam word may be truncated in `previous` (the
    /// reset can land mid-word), so the last compared pair also matches when one
    /// side is a ≥3-character prefix of the other.
    static func stripReplayedPrefix(_ text: String, previous: String, maxWords: Int = 8) -> String {
        let words = text.split(separator: " ").map(String.init)
        let prevWords = previous.split(separator: " ").map(String.init)
        let limit = min(words.count, prevWords.count, maxWords)
        guard limit > 0 else { return text }
        outer: for n in stride(from: limit, through: 1, by: -1) {
            for i in 0..<n {
                let a = words[i].lowercased()
                let b = prevWords[prevWords.count - n + i].lowercased()
                let same = a == b || (i == n - 1 && min(a.count, b.count) >= 3 && (a.hasPrefix(b) || b.hasPrefix(a)))
                if !same { continue outer }
            }
            return words.dropFirst(n).joined(separator: " ")
        }
        return text
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
    private static let sortformerConfig: SortformerConfig = .balancedV2_1
    private static let eendVariant: LSEENDVariant = .dihard3
    private let eouDebounceMs = 1280

    /// A downloaded+loaded diarizer model set, tagged with the backend it belongs to.
    private enum LoadedDiarizerModel {
        case sortformer(SortformerModels)
        case eend(LSEENDModel)
    }

    private var asr: StreamingEouAsrManager?
    private var loadedDiarizer: (backend: DiarizerBackend, model: LoadedDiarizerModel)?
    private var diarizer: (any Diarizer)?

    // Custom vocabulary rescoring: committed utterances are re-checked against the
    // configured terms using a CTC spotter model (~110MB, downloaded lazily the first
    // time terms exist). Best-effort — any failure logs and keeps the original text.
    private var ctcModels: CtcModels?
    private var vocabSession: VocabularyBoostingSession?
    private var vocabSessionTerms: [String] = []
    // Rolling tap-rate audio backing the rescorer, mapped to session time via
    // sessionAudioStartMs and trimmed as utterances commit.
    private var sessionAudio: [Float] = []
    private var sessionAudioStartMs = 0
    private var sessionAudioRate: Double = 16000
    private var sessionAudioUsable = true

    private var prepareRunning = false
    private var prepareWaiters: [CheckedContinuation<Void, Error>] = []
    private var sessionActive = false
    private var failed = false
    /// Accumulated transcript of the current ASR epoch that has already been emitted.
    private var emittedInEpoch = ""
    private var emittedTokenCount = 0
    /// Session time (ms) where the current ASR epoch started; token timestamps are
    /// epoch-relative and restart at zero each time the ASR resets after an EOU.
    private var tokenEpochMs = 0
    private var utteranceStartMs = 0
    private var pending: [Float] = []
    private var pendingRate: Double = 16000
    /// While an utterance commits, the ASR drains and resets — chunks decoded in
    /// that window would be discarded. Hold them in `pending` and process after.
    private var resetting = false
    private var chunksProcessed = 0
    /// Seconds of tap-rate audio fed to the ASR in the current epoch; the epoch
    /// boundary in session time is `tokenEpochMs + epochAudioFedSeconds`.
    private var epochAudioFedSeconds = 0.0
    /// Fake silence injected into the epoch at EOU commits (to flush the tail); token
    /// timestamps count it as epoch time, so it is subtracted when mapping to session time.
    private var epochInjectedMs = 0
    /// Tail of recently fed audio (tap rate), replayed into each fresh epoch:
    /// the cache-aware encoder blanks speech that starts without a low-energy
    /// lead-in after a reset (FluidAudio #838's failure class).
    private var recentAudio: [Float] = []
    private static let replayPrerollSeconds = 1.2
    /// Set when the commit before a reset decoded audio inside the replay window;
    /// the next commit then drops the re-decoded seam words.
    private var dedupeNextCommit = false
    private var lastCommitText = ""
    /// Deferred epoch reset: EOU latches until reset, but resetting zeroes the
    /// encoder caches — and a hard-to-decode voice starting right after the reset
    /// can be blanked entirely, preroll replay notwithstanding. So the reset waits
    /// until the pause provably persists: no new tokens AND quiet audio for
    /// `deferredQuietSeconds`. Speech resuming before that lands in the still-warm
    /// epoch and decodes normally.
    private var epochNeedsReset = false
    private static let deferredQuietSeconds = 1.0
    private static let speechRmsGate = 0.01
    private var lastTokenCount = 0
    private var lastTokensAtFedSeconds = 0.0
    private var lastLoudAtFedSeconds = 0.0

    private var onSegment: (@Sendable (SpeakerSegment) -> Void)?
    private var onPartial: (@Sendable (String) -> Void)?
    private var onError: (@Sendable (String) -> Void)?

    func setHandlers(onSegment: (@Sendable (SpeakerSegment) -> Void)?,
                     onPartial: (@Sendable (String) -> Void)?,
                     onError: (@Sendable (String) -> Void)?) {
        self.onSegment = onSegment; self.onPartial = onPartial; self.onError = onError
    }

    /// Downloads (first run only) and loads the ASR models plus the selected diarizer's model.
    /// Concurrent callers wait for the same prepare. `progress` receives (fraction 0…1, stage label).
    /// LS-EEND's loader does not report download progress, so its phase only emits endpoints.
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let backend = DiarizerBackend.saved
        if asr != nil, loadedDiarizer?.backend == backend { progress(1, "On-device speech ready"); return }
        if prepareRunning {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in prepareWaiters.append(cont) }
            return
        }
        prepareRunning = true
        do {
            if asr == nil {
                progress(0.02, "Preparing speech recognition")
                let manager = StreamingEouAsrManager(chunkSize: Self.chunkSize, eouDebounceMs: eouDebounceMs)
                try await manager.loadModels(to: nil, configuration: nil) { p in
                    progress(0.02 + p.fractionCompleted * 0.48, "Downloading speech recognition")
                }
                asr = manager
            }
            progress(0.5, "Preparing speaker separation")
            let model: LoadedDiarizerModel
            switch backend {
            case .sortformer:
                model = .sortformer(try await SortformerModels.loadFromHuggingFace(config: Self.sortformerConfig) { p in
                    progress(0.5 + p.fractionCompleted * 0.48, "Downloading speaker separation")
                })
            case .eend:
                progress(0.5, "Downloading speaker separation")
                // LS-EEND is CPU-optimized by design; keeping it off the ANE also avoids
                // contending with the ASR models there.
                model = .eend(try await LSEENDModel.loadFromHuggingFace(variant: Self.eendVariant, stepSize: .step100ms))
            }
            loadedDiarizer = (backend, model)
            let vocabTerms = CustomVocabulary.saved
            if !vocabTerms.isEmpty {
                progress(0.98, "Preparing custom vocabulary")
                await prepareVocabularyBoosting(terms: vocabTerms)
            }
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
        guard let asr, let loadedDiarizer else {
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
        switch loadedDiarizer.model {
        case .sortformer(let models):
            let sortformer = SortformerDiarizer(config: Self.sortformerConfig)
            sortformer.initialize(models: models)
            diarizer = sortformer
        case .eend(let model):
            diarizer = try LSEENDDiarizer(model: model)
        }
        // Picks up term edits made while the models were already warm; no-op when unchanged.
        await prepareVocabularyBoosting(terms: CustomVocabulary.saved)
        NSLog("[fluid] diarizer: %@ (%d speaker slots)", loadedDiarizer.backend.rawValue, diarizer?.numSpeakers ?? 0)
        emittedInEpoch = ""; utteranceStartMs = 0; pending = []; emittedTokenCount = 0; tokenEpochMs = 0
        epochAudioFedSeconds = 0; epochInjectedMs = 0; recentAudio = []; dedupeNextCommit = false; lastCommitText = ""
        epochNeedsReset = false; lastTokenCount = 0; lastTokensAtFedSeconds = 0; lastLoudAtFedSeconds = 0
        sessionAudio = []; sessionAudioStartMs = 0; sessionAudioUsable = true
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
        if vocabSession != nil { retainSessionAudio(samples, rate: pendingRate) }
        // If inference ever falls behind realtime, drop the oldest audio instead of growing memory.
        let cap = Int(pendingRate * 30)
        if pending.count > cap { pending.removeFirst(pending.count - cap) }
        let chunkTarget = Int(pendingRate * 0.5)
        // While a commit resets the ASR epoch, hold incoming audio and process it after.
        guard !resetting else { return }
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
        epochNeedsReset = false
        epochInjectedMs = 0
        if !pending.isEmpty {
            let tail = pending; pending = []
            await processChunk(tail, rate: pendingRate)
        }
        if let diarizer { _ = try? diarizer.finalizeSession() }
        if let asr {
            // finish() clears the accumulated tokens and timestamps; snapshot them first.
            let timestamps = await asr.getTokenTimestampsMs()
            let tokens = await asr.getRawTokenStrings()
            if let full = try? await asr.finish() {
                await emit(accumulated: full, tokenTimestamps: timestamps, rawTokenStrings: tokens)
                await asr.reset()
            }
        }
        diarizer = nil
        failed = false
        sessionAudio = []; sessionAudioStartMs = 0
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
                epochAudioFedSeconds += Double(samples.count) / rate
                recentAudio.append(contentsOf: samples)
                let keep = Int(rate * (Self.replayPrerollSeconds + 0.5))
                if recentAudio.count > keep { recentAudio.removeFirst(recentAudio.count - keep) }
                var energy = 0.0
                for s in samples { energy += Double(s) * Double(s) }
                if sqrt(energy / Double(samples.count)) > Self.speechRmsGate { lastLoudAtFedSeconds = epochAudioFedSeconds }
                let tokenCount = await asr.getTokenTimestampsMs().count
                if tokenCount != lastTokenCount {
                    lastTokenCount = tokenCount
                    lastTokensAtFedSeconds = epochAudioFedSeconds
                }
                if epochNeedsReset,
                   epochAudioFedSeconds - max(lastLoudAtFedSeconds, lastTokensAtFedSeconds) >= Self.deferredQuietSeconds {
                    await finalizeDeferredEpoch()
                }
            } catch { fail("On-device transcription failed: \(error.localizedDescription)") }
        }
    }

    private func fail(_ message: String) {
        guard !failed else { return }
        NSLog("[fluid] error: %@", message)
        failed = true; sessionActive = false
        onError?(message)
    }

    /// The EOU callback carries the current epoch's accumulated transcript, so the new
    /// utterance is the diff against what was already emitted. Utterance bounds come from
    /// the ASR's per-token timestamps, which are far more accurate than the EOU
    /// confirmation time (that trails speech by the debounce window).
    ///
    /// EOU latches per epoch — `eouDetected` blocks any further confirmation until
    /// `reset()` — but the reset is DEFERRED (see finalizeDeferredEpoch): the commit
    /// happens immediately, while the epoch stays warm for speech that resumes quickly.
    private func utteranceEnded(accumulated: String) async {
        guard sessionActive, !failed, let asr else { return }
        resetting = true
        defer { resetting = false }
        // The callback's transcript snapshot lags: decoding continues through the debounce
        // window and the tail chunk may still be buffered. Drain it (padding to a full
        // chunk) so the commit carries the complete utterance. The injected silence stays
        // in the epoch (no reset yet) and is tracked in epochInjectedMs.
        await asr.injectSilence(0.7)
        epochInjectedMs += 700
        try? await asr.processBufferedAudio()
        let latest = await asr.getPartialTranscript()
        await emit(accumulated: latest.isEmpty ? accumulated : latest)
        epochNeedsReset = true
        // Process whatever arrived mid-commit into the same, still-warm epoch.
        let chunkTarget = Int(pendingRate * 0.5)
        while pending.count >= chunkTarget {
            let chunk = Array(pending.prefix(chunkTarget))
            pending.removeFirst(chunkTarget)
            await processChunk(chunk, rate: pendingRate)
        }
    }

    /// Commits whatever accumulated since the EOU commit, then resets the epoch.
    /// Runs only once the pause provably persists — no new tokens AND quiet audio for
    /// `deferredQuietSeconds` — so an utterance starting right after the EOU lands in
    /// the still-warm epoch instead of a freshly zeroed one (whose cache-aware encoder
    /// can blank speech, FluidAudio #838's failure class; preroll replay of quiet
    /// pause audio alone did not warm it enough for hard-to-decode voices).
    /// While the reset is pending, EOU stays latched, so this silence rule is also
    /// what splits a follow-up utterance after a ≥~1.5s pause.
    private func finalizeDeferredEpoch() async {
        guard sessionActive, !failed, epochNeedsReset, let asr else { return }
        epochNeedsReset = false
        resetting = true
        defer { resetting = false }
        let latest = await asr.getPartialTranscript()
        await emit(accumulated: latest)
        await resetEpoch(asr)
        // Process whatever arrived mid-reset in the fresh epoch.
        let chunkTarget = Int(pendingRate * 0.5)
        while pending.count >= chunkTarget {
            let chunk = Array(pending.prefix(chunkTarget))
            pending.removeFirst(chunkTarget)
            await processChunk(chunk, rate: pendingRate)
        }
    }

    /// Resets the ASR epoch and re-feeds the tail of the pause into the fresh epoch.
    /// The replay ends exactly where the held pending audio resumes, so no audio is
    /// skipped or double-fed. `tokenEpochMs` is derived from the fed-sample count,
    /// which makes it exact (the previous `getEouTimestampsMs` approximation trailed
    /// by the decode lag).
    private func resetEpoch(_ asr: StreamingEouAsrManager) async {
        let resetPointMs = tokenEpochMs + Int(epochAudioFedSeconds * 1000)
        let prerollSamples = min(Int(Self.replayPrerollSeconds * pendingRate), recentAudio.count)
        let prerollMs = prerollSamples * 1000 / max(Int(pendingRate), 1)
        // The seam can only repeat text when the commit just made (`utteranceStartMs`
        // is now its end) decoded audio inside the replay window.
        let seamOverlap = utteranceStartMs > resetPointMs - prerollMs
        await asr.reset()
        if prerollSamples > 0, let pcm = Self.monoBuffer(Array(recentAudio.suffix(prerollSamples)), rate: pendingRate) {
            try? await asr.appendAudio(pcm)
            try? await asr.processBufferedAudio()
        }
        tokenEpochMs = resetPointMs - prerollMs
        epochAudioFedSeconds = Double(prerollSamples) / pendingRate
        epochInjectedMs = 0
        emittedInEpoch = ""; emittedTokenCount = 0
        dedupeNextCommit = seamOverlap
        lastTokenCount = 0
        lastTokensAtFedSeconds = epochAudioFedSeconds
        lastLoudAtFedSeconds = epochAudioFedSeconds
        NSLog("[fluid] epoch reset: replayed %dms preroll, held %d pending samples", prerollMs, pending.count)
    }

    private func emit(accumulated: String, tokenTimestamps: [Int]? = nil, rawTokenStrings: [String]? = nil) async {
        let fresh = accumulated.hasPrefix(emittedInEpoch) ? String(accumulated.dropFirst(emittedInEpoch.count)) : accumulated
        let text = fresh.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { emittedInEpoch = accumulated }
        guard !text.isEmpty else { return }
        var startMs = max(utteranceStartMs, tokenEpochMs)
        var endMs = startMs
        var stamps: [Int] = []
        var newTokenIndex = 0
        if let asr {
            let raw: [Int]
            if let tokenTimestamps { raw = tokenTimestamps }
            else { raw = await asr.getTokenTimestampsMs() }
            // Token counts can shrink at chunk seams (temporal dedup), so re-sync
            // rather than assuming append-only growth.
            let count = min(emittedTokenCount, raw.count)
            if raw.count > count {
                let newTokens = raw[count...]
                // Token stamps count injected commit-flush silence as epoch time.
                startMs = newTokens.first.map { $0 + tokenEpochMs - epochInjectedMs } ?? startMs
                endMs = (newTokens.last.map { $0 + tokenEpochMs - epochInjectedMs } ?? startMs) + Self.chunkSize.durationMs
            }
            emittedTokenCount = raw.count
            stamps = raw
            newTokenIndex = count
        }
        // Rescore the unstripped text: it must match the token timings word-for-word.
        var committed = text
        if vocabSession != nil, newTokenIndex < stamps.count {
            let tokens: [String]
            if let rawTokenStrings { tokens = rawTokenStrings }
            else if let asr { tokens = await asr.getRawTokenStrings() }
            else { tokens = [] }
            if let corrected = await rescoreCommittedUtterance(text, startMs: startMs, endMs: endMs,
                                                               timestamps: stamps, tokens: tokens, from: newTokenIndex) {
                committed = corrected
            }
            // Audio behind this utterance (minus preroll for the next) is never rescored again.
            trimSessionAudio(beforeMs: endMs - 1000)
        }
        if dedupeNextCommit {
            // The replayed preroll re-decoded speech the previous epoch committed.
            dedupeNextCommit = false
            let stripped = TranscriptSeam.stripReplayedPrefix(committed, previous: lastCommitText)
            if stripped != committed { NSLog("[fluid] seam dedupe: '%@' -> '%@'", committed, stripped) }
            committed = stripped
        }
        guard !committed.isEmpty else { return }
        utteranceStartMs = endMs
        let startS = Double(startMs) / 1000
        let speaker = dominantSpeaker(start: startS, end: Double(endMs) / 1000 + 0.2)
        NSLog("[fluid] utterance committed speaker=%d start=%.1fs: %@", speaker, startS, committed)
        lastCommitText = committed
        onSegment?(SpeakerSegment(speaker: speaker, text: committed, start: startS))
    }

    /// Builds (or tears down) the CTC vocabulary-boosting session for the given terms.
    /// Loads the spotter model lazily on first use; failures disable boosting rather
    /// than affecting transcription.
    private func prepareVocabularyBoosting(terms: [String]) async {
        guard !terms.isEmpty else { vocabSession = nil; vocabSessionTerms = []; return }
        guard vocabSession == nil || terms != vocabSessionTerms else { return }
        do {
            if ctcModels == nil {
                NSLog("[fluid] custom vocabulary: preparing CTC spotter model (one-time download if needed)")
                ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
            }
            let tokenizer = try await CtcTokenizer.load(from: CtcModels.defaultCacheDirectory(for: .ctc110m))
            let vocabTerms = terms.compactMap { term -> CustomVocabularyTerm? in
                let ids = tokenizer.encode(term)
                return ids.isEmpty ? nil : CustomVocabularyTerm(text: term, weight: 10.0, ctcTokenIds: ids)
            }
            guard !vocabTerms.isEmpty, let ctcModels else {
                vocabSession = nil; vocabSessionTerms = terms
                return
            }
            vocabSession = try await VocabularyBoostingSession(
                vocabulary: CustomVocabularyContext(terms: vocabTerms), ctcModels: ctcModels)
            vocabSessionTerms = terms
            NSLog("[fluid] custom vocabulary boosting active (%d terms)", vocabTerms.count)
        } catch {
            NSLog("[fluid] custom vocabulary unavailable, continuing without corrections: %@", error.localizedDescription)
            vocabSession = nil
        }
    }

    private func retainSessionAudio(_ samples: [Float], rate: Double) {
        guard sessionAudioUsable else { return }
        guard rate == sessionAudioRate else {
            // A mid-session rate change breaks the sample→time mapping; disable
            // retention rather than rescore against misaligned audio.
            NSLog("[fluid] tap sample rate changed mid-session; vocabulary rescoring disabled until next Listen")
            sessionAudio = []; sessionAudioUsable = false
            return
        }
        sessionAudio.append(contentsOf: samples)
        // Hard bound for pathological no-EOU stretches; committed utterances are far shorter.
        let cap = Int(sessionAudioRate * 60)
        if sessionAudio.count > cap { dropSessionAudio(sessionAudio.count - cap) }
    }

    private func dropSessionAudio(_ count: Int) {
        let dropped = min(max(count, 0), sessionAudio.count)
        guard dropped > 0 else { return }
        sessionAudio.removeFirst(dropped)
        sessionAudioStartMs += dropped * 1000 / Int(sessionAudioRate)
    }

    private func trimSessionAudio(beforeMs: Int) {
        dropSessionAudio((beforeMs - sessionAudioStartMs) * Int(sessionAudioRate) / 1000)
    }

    /// Session-time window of the retained tap audio, nil when it fell outside the
    /// retained range.
    private func sessionAudioSlice(fromMs: Int, toMs: Int) -> [Float]? {
        let rate = Int(sessionAudioRate)
        let start = (fromMs - sessionAudioStartMs) * rate / 1000
        let end = min((toMs - sessionAudioStartMs) * rate / 1000, sessionAudio.count)
        guard start >= 0, end > start else { return nil }
        return Array(sessionAudio[start..<end])
    }

    /// Re-checks a committed utterance against the custom vocabulary using CTC acoustic
    /// evidence over the utterance's retained audio. Returns the corrected text, or nil
    /// to keep the original.
    private func rescoreCommittedUtterance(_ text: String, startMs: Int, endMs: Int,
                                           timestamps: [Int], tokens: [String], from index: Int) async -> String? {
        guard let vocabSession else { return nil }
        // Pre/post-roll so the CTC pass sees word onsets at the slice edges.
        let sliceStartMs = max(0, startMs - 500)
        guard let slice = sessionAudioSlice(fromMs: sliceStartMs, toMs: endMs + 500) else { return nil }
        let count = min(timestamps.count, tokens.count)
        guard index < count else { return nil }
        // Token timings on the slice's clock (t=0 at the first sample); the rescorer
        // groups SentencePiece "▁"-prefixed tokens into words and never reads tokenId.
        var timings: [TokenTiming] = []
        for i in index..<count {
            let tokenStartMs = timestamps[i] + tokenEpochMs - epochInjectedMs
            let nextMs = i + 1 < count ? timestamps[i + 1] + tokenEpochMs - epochInjectedMs : endMs
            timings.append(TokenTiming(
                token: tokens[i], tokenId: 0,
                startTime: Double(tokenStartMs - sliceStartMs) / 1000,
                endTime: Double(max(nextMs, tokenStartMs) - sliceStartMs) / 1000,
                confidence: 1))
        }
        do {
            let samples = try AudioConverter().resample(slice, from: sessionAudioRate)
            guard let output = await vocabSession.rescore(text: text, tokenTimings: timings, audioSamples: samples) else { return nil }
            let corrected = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !corrected.isEmpty, corrected != text else { return nil }
            NSLog("[fluid] vocabulary correction: %@ → %@", text, corrected)
            return corrected
        } catch {
            NSLog("[fluid] vocabulary rescoring failed, keeping original text: %@", error.localizedDescription)
            return nil
        }
    }

    private func partialUpdated(_ accumulated: String) {
        guard sessionActive, !failed, accumulated.hasPrefix(emittedInEpoch) else { return }
        let tail = String(accumulated.dropFirst(emittedInEpoch.count)).trimmingCharacters(in: .whitespacesAndNewlines)
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
