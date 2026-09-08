// ScreenAudioManager — always-on SYSTEM AUDIO capture via CoreAudio process tap (macOS 14.2+)
// → rolling on-device transcription. No ScreenCaptureKit: a private tap + aggregate device
// does NOT light up the purple screen-recording menu-bar indicator.
// Recognition requests die after ~1 minute, so tasks are rotated continuously; each window's
// last partial is committed as a final transcript line before rotating.
import Foundation
import CoreAudio
import AVFoundation
@preconcurrency import Speech

// Restarting recognition must not invalidate a still-running hardware callback.
struct AudioCaptureLifecycle {
    private(set) var capture = 0
    private(set) var recognition = 0
    mutating func rotateRecognition() { recognition += 1 }
    mutating func stop() { capture += 1; recognition += 1 }
    func acceptsAudio(_ token: Int) -> Bool { capture == token }
}

// Nonisolated + @unchecked Sendable: every piece of mutable state lives on `queue`.
// Audio/Speech callbacks arrive on background threads — under Swift 6 an isolated closure
// traps there, so handlers are @Sendable and capture only Sendable values (strong self;
// this object lives for the app's lifetime).
final class ScreenAudioManager: NSObject, @unchecked Sendable {
    var onTranscript: (@MainActor (_ text: String, _ isFinal: Bool) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    var onSpeakerTranscript: (@MainActor (SpeakerSegment) -> Void)?
    var onLevel: (@MainActor (Double) -> Void)?
    private var localConfiguration: LocalSpeechConfiguration?
    private var localSpeech: LocalSpeechStream?
    private var lastLevelTime = Date.distantPast

    private let queue = DispatchQueue(label: "kura.screenaudio")
    private var ioProcID: AudioDeviceIOProcID?
    private var compatibilityEngine: AVAudioEngine?
    private var tapID = AudioObjectID()
    private var aggregateID = AudioObjectID()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var rotationTimer: DispatchSourceTimer?
    private var lifecycle = AudioCaptureLifecycle()
    private var generation: Int { lifecycle.recognition }
    private var lastText = ""
    private var committer = IncrementalTranscriptCommitter()
    private var turnBoundary = SpeechTurnBoundary()
    private var consecutiveFailures = 0
    private var loggedFirstBuffer = false
    private var running = false

    // AVAudioPCMBuffer is not Sendable; boxes let tap callbacks cross to `queue` cleanly.
    private struct SendablePCMBuffer: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }

    private struct TapError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Lifecycle

    func start(localConfiguration: LocalSpeechConfiguration? = nil) {
        queue.async { [self] in
            guard !running else { return }
            self.localConfiguration = localConfiguration
            CaptureDiagnostics.shared.reset()
            CaptureDiagnostics.shared.stage("Creating system audio tap")
            running = true
            setupCaptureLocked()
        }
    }

    func stop() {
        queue.async { [self] in teardownLocked() }
    }

    func stopAndDrain() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let client = localSpeech; localSpeech = nil
                teardownLocked()
                if let client { client.stop { continuation.resume() } }
                else { continuation.resume() }
            }
        }
    }

    private func setupCaptureLocked() {
        guard #available(macOS 14.2, *) else {
            reportError("process tap requires macOS 14.2 or later")
            teardownLocked()
            return
        }
        do {
            // 1. Global stereo mix of all processes, private to this process, unmuted.
            let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            desc.isPrivate = true
            desc.muteBehavior = .unmuted
            var tapID = AudioObjectID()
            var err = AudioHardwareCreateProcessTap(desc, &tapID)
            guard err == noErr else {
                throw TapError(message: "AudioHardwareCreateProcessTap failed (OSStatus \(err))")
            }
            self.tapID = tapID
            CaptureDiagnostics.shared.stage("Reading tap identity")

            // 2. The tap's UID is needed to reference it from the aggregate device.
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var tapUIDRef: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            err = AudioObjectGetPropertyData(tapID, &uidAddr, 0, nil, &uidSize, &tapUIDRef)
            guard err == noErr, let tapUID = tapUIDRef?.takeRetainedValue() as String? else {
                throw TapError(message: "could not read tap UID (OSStatus \(err))")
            }

            // 3. Private aggregate device wrapping the tap, auto-started.
            let aggDesc: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Kura Audio Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceIsPrivateKey: true,
            ]
            var aggregateID = AudioObjectID()
            CaptureDiagnostics.shared.stage("Creating aggregate audio device")
            err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateID)
            guard err == noErr else {
                throw TapError(message: "AudioHardwareCreateAggregateDevice failed (OSStatus \(err))")
            }
            self.aggregateID = aggregateID
            CaptureDiagnostics.shared.stage("Reading audio format")

            if UserDefaults.standard.string(forKey: "systemAudioCaptureDriver") == "cloak" {
                try setupCompatibilityEngine(aggregateID: aggregateID)
            } else {

            // Read directly from the tap. AVAudioEngine.inputNode initializes the default
            // microphone first and can hang in the HAL before we can assign this device.
            var asbd = AudioStreamBasicDescription()
            var fmtAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            err = AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &fmtSize, &asbd)
            guard err == noErr, asbd.mSampleRate > 0, asbd.mBytesPerFrame > 0,
                  let format = AVAudioFormat(streamDescription: &asbd), format.commonFormat == .pcmFormatFloat32 else {
                throw TapError(message: "Unsupported system audio format (OSStatus \(err))")
            }
            let bytesPerFrame = asbd.mBytesPerFrame
            let captureGeneration = lifecycle.capture
            NSLog("[screenaudio] tap %u aggregate %u format %@", tapID, aggregateID, format.description)
            CaptureDiagnostics.shared.stage("Registering audio callback")
            err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { [weak self] _, inputData, _, _, _ in
                guard let self else { return }
                let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
                guard let first = source.first else { return }
                let frames = first.mDataByteSize / bytesPerFrame
                guard frames > 0, let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
                copy.frameLength = frames
                let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                guard source.count == destination.count else {
                    CaptureDiagnostics.shared.reject("Audio buffer layout mismatch: \(source.count) inputs, \(destination.count) expected")
                    return
                }
                for i in source.indices {
                    guard source[i].mDataByteSize <= destination[i].mDataByteSize,
                          let src = source[i].mData, let dst = destination[i].mData else {
                        CaptureDiagnostics.shared.reject("Audio buffer is missing data or exceeds capacity")
                        return
                    }
                    memcpy(dst, src, Int(source[i].mDataByteSize))
                }
                let boxed = SendablePCMBuffer(copy)
                self.queue.async { [self] in
                    guard running, lifecycle.acceptsAudio(captureGeneration) else { return }
                    if !loggedFirstBuffer {
                        loggedFirstBuffer = true
                        NSLog("[screenaudio] first audio buffer received")
                    }
                    processBufferLocked(boxed.buffer)
                }
            }
            guard err == noErr, let ioProcID else { throw TapError(message: "Could not register audio callback (OSStatus \(err))") }
            CaptureDiagnostics.shared.stage("Starting audio device")
            err = AudioDeviceStart(aggregateID, ioProcID)
            guard err == noErr else { throw TapError(message: "Could not start system audio (OSStatus \(err)). Check Settings → Permissions.") }
            NSLog("[screenaudio] capture started (process tap)")
            }

            if localConfiguration != nil { CaptureDiagnostics.shared.stage("Waiting for audio · local speech"); return }
            CaptureDiagnostics.shared.stage("Checking Apple speech authorization")

            // Recognition starts once speech is authorized; capture already runs.
            // (requestAuthorization can hang for minutes behind a TCC prompt.)
            // Generation guard: a continuation from a previous start cycle must not
            // start (or tear down) recognition for the current one.
            let gen = generation
            Task { [self] in
                guard await Self.requestSpeechAuthorization() else {
                    queue.async { [self] in
                        guard generation == gen, running else { return }
                        reportError("speech recognition not authorized")
                        teardownLocked()
                    }
                    return
                }
                queue.async { [self] in
                    guard generation == gen, running else { return }
                    startRecognitionLocked()
                }
            }
        } catch {
            reportError("process tap failed: \(error.localizedDescription)")
            teardownLocked()
        }
    }

    nonisolated private static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    // Cloak's original capture route, retained for controlled A/B troubleshooting.
    // Keep copied buffers and separate capture lifetime protection from the newer path.
    private func setupCompatibilityEngine(aggregateID: AudioObjectID) throws {
        CaptureDiagnostics.shared.stage("Cloak compatibility · initializing AVAudioEngine input")
        let engine = AVAudioEngine()
        compatibilityEngine = engine
        let input = engine.inputNode
        guard let audioUnit = input.audioUnit else { throw TapError(message: "Compatibility input node has no audio unit") }
        CaptureDiagnostics.shared.stage("Cloak compatibility · assigning tap device")
        var device = aggregateID
        let err = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioObjectID>.size))
        guard err == noErr else { throw TapError(message: "Compatibility device assignment failed (OSStatus \(err))") }
        var format = input.outputFormat(forBus: 0)
        if format.sampleRate == 0 {
            var asbd = AudioStreamBasicDescription()
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat,
                mScope: kAudioDevicePropertyScopeInput, mElement: 1)
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let status = AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &asbd)
            guard status == noErr, asbd.mSampleRate > 0, let fallback = AVAudioFormat(streamDescription: &asbd) else {
                throw TapError(message: "Compatibility audio format unavailable (OSStatus \(status))")
            }
            format = fallback
        }
        let captureToken = lifecycle.capture
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable [weak self] buffer, _ in
            guard let self, let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
            let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            guard source.count == destination.count else { CaptureDiagnostics.shared.reject("Compatibility buffer layout mismatch"); return }
            for i in source.indices {
                guard source[i].mDataByteSize <= destination[i].mDataByteSize, let src = source[i].mData, let dst = destination[i].mData else {
                    CaptureDiagnostics.shared.reject("Compatibility audio buffer missing data"); return
                }
                memcpy(dst, src, Int(source[i].mDataByteSize))
            }
            let boxed = SendablePCMBuffer(copy)
            self.queue.async { [self] in
                guard running, lifecycle.acceptsAudio(captureToken) else { return }
                processBufferLocked(boxed.buffer)
            }
        }
        CaptureDiagnostics.shared.stage("Cloak compatibility · starting engine")
        engine.prepare()
        try engine.start()
    }

    private func teardownLocked() {
        commitLastLocked()
        localSpeech?.stop(); localSpeech = nil
        running = false
        CaptureDiagnostics.shared.stage("Stopping audio device")
        lifecycle.stop()
        rotationTimer?.cancel()
        rotationTimer = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        lastText = ""
        consecutiveFailures = 0
        loggedFirstBuffer = false
        if let engine = compatibilityEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            compatibilityEngine = nil
        }
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != 0 {
            if #available(macOS 14.2, *) { AudioHardwareDestroyAggregateDevice(aggregateID) }
            aggregateID = 0
        }
        if tapID != 0 {
            if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
            tapID = 0
        }
        NSLog("[screenaudio] capture stopped")
        CaptureDiagnostics.shared.stage("Stopped")
    }

    // MARK: Recognition with rotation (all on `queue`)

    private func startRecognitionLocked() {
        guard running else { return }
        CaptureDiagnostics.shared.stage("Starting Apple recognition")
        if recognizer == nil {
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        }
        guard let recognizer, recognizer.isAvailable else {
            reportError("speech recognizer unavailable")
            teardownLocked()
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        req.shouldReportPartialResults = true
        request = req
        turnBoundary = SpeechTurnBoundary()
        committer = IncrementalTranscriptCommitter()
        let recognitionStarted = ProcessInfo.processInfo.systemUptime
        let gen = generation
        recognitionTask = recognizer.recognitionTask(with: req) { @Sendable result, error in
            // Extract plain values here — SFSpeechRecognitionResult is not Sendable.
            let text = result?.bestTranscription.formattedString ?? ""
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            if let error = error as NSError? {
                CaptureDiagnostics.shared.issue("Apple speech error: \(error.domain) (\(error.code))")
            }
            self.queue.async { [self] in
                guard generation == gen else { return }
                if !text.isEmpty {
                    CaptureDiagnostics.shared.recognitionResult()
                    lastText = text
                    // Commit the stable head incrementally; only the tail stays
                    // open to Apple's revisions. One Task keeps commit-then-
                    // partial ordering on the main actor.
                    let chunk = committer.observe(text)
                    let remainder = committer.remainder(for: text)
                    turnBoundary.observe(text: remainder, at: ProcessInfo.processInfo.systemUptime)
                    let cb = onTranscript
                    if !isFinal || chunk != nil {
                        Task { @MainActor in
                            if let chunk { await cb?(chunk, true) }
                            if !isFinal { await cb?(remainder, false) }
                        }
                    }
                }
                if failed || isFinal {
                    guard running else { return }
                    recognitionEndedLocked(failed: failed)
                }
            }
        }
        NSLog("[screenaudio] recognition task started (gen %d)", gen)
        CaptureDiagnostics.shared.stage("Apple recognition running")

        rotationTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
        timer.setEventHandler { [self] in
            guard generation == gen, running else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if turnBoundary.shouldFinish(at: now) || now - recognitionStarted >= 55 {
                // Commit the stable turn once, then rotate recognition only.
                // Hardware capture continues; old callbacks fail the generation guard.
                rotateLocked()
            }
        }
        rotationTimer = timer
        timer.resume()
    }

    /// Proactive rotation before the ~1-minute task lifetime kills recognition mid-sentence.
    private func rotateLocked() {
        commitLastLocked()
        lifecycle.rotateRecognition()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        consecutiveFailures = 0
        startRecognitionLocked()
    }

    /// The task died on its own (error or final) — restart it so transcription is seamless.
    private func recognitionEndedLocked(failed: Bool) {
        commitLastLocked()
        lifecycle.rotateRecognition()
        recognitionTask = nil
        request = nil
        consecutiveFailures = failed ? consecutiveFailures + 1 : 0
        guard consecutiveFailures <= 5 else {
            reportError("speech recognition repeatedly failed — always-on stopped")
            teardownLocked()
            return
        }
        let restartGeneration = generation
        queue.asyncAfter(deadline: .now() + 0.5) { [self] in
            guard running, generation == restartGeneration else { return }
            startRecognitionLocked()
        }
    }

    private func commitLastLocked() {
        // The stable head was already committed incrementally; only the tail remains.
        let text = committer.remainder(for: lastText).trimmingCharacters(in: .whitespacesAndNewlines)
        lastText = ""
        guard !text.isEmpty, let cb = onTranscript else { return }
        Task { await cb(text, true) }
    }

    private func processBufferLocked(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { request?.append(buffer); return }
        let count = Int(buffer.frameLength); let channelCount = Int(buffer.format.channelCount)
        guard count > 0, channelCount > 0 else { return }
        var mono = [Int16](repeating: 0, count: count); var energy = 0.0
        for frame in 0..<count {
            var value: Float = 0
            for channel in 0..<channelCount {
                value += buffer.format.isInterleaved ? channels[0][frame * channelCount + channel] : channels[channel][frame]
            }
            value /= Float(channelCount)
            energy += Double(value * value)
            mono[frame] = Int16(max(-32767, min(32767, value * 32767)))
        }
        if Date().timeIntervalSince(lastLevelTime) > 0.15 {
            lastLevelTime = Date(); let level = min(1, sqrt(energy / Double(count)) * 5); let cb = onLevel
            Task { await cb?(level) }
        }
        let rms = sqrt(energy / Double(count))
        turnBoundary.observe(rms: rms, at: ProcessInfo.processInfo.systemUptime)
        CaptureDiagnostics.shared.buffer(level: rms)
        if let configuration = localConfiguration {
            if localSpeech == nil {
                let segmentCB = onSpeakerTranscript; let errorCB = onError
                do {
                    localSpeech = try LocalSpeechStream(configuration: configuration, sampleRate: buffer.format.sampleRate, onSegments: { segments in
                        Task { @MainActor in for segment in segments { segmentCB?(segment) } }
                    }, onError: { error in Task { await errorCB?(error) } })
                } catch { reportError(error.localizedDescription); teardownLocked(); return }
            }
            localSpeech?.send(mono.withUnsafeBytes { Data($0) })
        } else { request?.append(buffer) }
    }

    private func reportError(_ message: String) {
        CaptureDiagnostics.shared.issue(message)
        NSLog("[screenaudio] error: %@", message)
        let cb = onError
        Task { await cb?(message) }
    }
}

/*
// MARK: - Legacy ScreenCaptureKit backend (unused — kept for reference)
// Retired because SCStream lights up the purple screen-recording menu-bar indicator.
// Re-enable only behind a deliberate decision; requires `import ScreenCaptureKit`,
// `final class ScreenAudioManager: NSObject, SCStreamOutput, ...`, and restoring the
// SCStream/SCStreamConfiguration setup plus the CMSampleBuffer→AVAudioPCMBuffer converter:

func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .audio, let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
    queue.async { [self] in request?.append(pcm) }
}

private static let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

private static func pcmBuffer(from sbuf: CMSampleBuffer) -> AVAudioPCMBuffer? { ... }
// (full implementation in git history / prior session handoff)
*/
