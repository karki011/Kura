// ScreenAudioManager — always-on SYSTEM AUDIO capture via CoreAudio process tap (macOS 14.2+)
// → rolling on-device transcription. No ScreenCaptureKit: a private tap + aggregate device
// does NOT light up the purple screen-recording menu-bar indicator.
// Recognition requests die after ~1 minute, so tasks are rotated continuously; each window's
// last partial is committed as a final transcript line before rotating.
import Foundation
import CoreAudio
import AVFoundation
@preconcurrency import Speech

// Nonisolated + @unchecked Sendable: every piece of mutable state lives on `queue`.
// Audio/Speech callbacks arrive on background threads — under Swift 6 an isolated closure
// traps there, so handlers are @Sendable and capture only Sendable values (strong self;
// this object lives for the app's lifetime).
final class ScreenAudioManager: NSObject, @unchecked Sendable {
    var onTranscript: (@MainActor (_ text: String, _ isFinal: Bool) -> Void)?
    var onError: (@MainActor (String) -> Void)?

    private let queue = DispatchQueue(label: "kura.screenaudio")
    private var engine: AVAudioEngine?
    private var tapID = AudioObjectID()
    private var aggregateID = AudioObjectID()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var rotationTimer: DispatchSourceTimer?
    private var generation = 0
    private var lastText = ""
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

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            setupCaptureLocked()
        }
    }

    func stop() {
        queue.async { [self] in teardownLocked() }
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
            err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateID)
            guard err == noErr else {
                throw TapError(message: "AudioHardwareCreateAggregateDevice failed (OSStatus \(err))")
            }
            self.aggregateID = aggregateID

            // 4. Point the engine's input at the aggregate device.
            let engine = AVAudioEngine()
            self.engine = engine
            let input = engine.inputNode
            guard let audioUnit = input.audioUnit else {
                throw TapError(message: "input node has no audio unit")
            }
            var deviceID = aggregateID
            err = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0,
                                       &deviceID, UInt32(MemoryLayout<AudioObjectID>.size))
            guard err == noErr else {
                throw TapError(message: "could not assign tap device to engine (OSStatus \(err))")
            }

            // 5. Tap format: engine-reported, falling back to the device's stream format
            //    (outputFormat reports a zero sample rate until the device has run once).
            var format = input.outputFormat(forBus: 0)
            if format.sampleRate == 0 {
                var asbd = AudioStreamBasicDescription()
                var fmtAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyStreamFormat,
                    mScope: kAudioDevicePropertyScopeInput,
                    mElement: 1)
                var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                err = AudioObjectGetPropertyData(aggregateID, &fmtAddr, 0, nil, &fmtSize, &asbd)
                guard err == noErr, asbd.mSampleRate > 0,
                      let deviceFormat = AVAudioFormat(streamDescription: &asbd) else {
                    throw TapError(message: "could not determine tap device format (OSStatus \(err))")
                }
                format = deviceFormat
            }
            NSLog("[screenaudio] tap %u aggregate %u format %@", tapID, aggregateID, format.description)

            // 6. Feed buffers into the (rotating) recognition request, same as the mic path.
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
                let boxed = SendablePCMBuffer(buffer)
                self.queue.async { [self] in
                    if !loggedFirstBuffer {
                        loggedFirstBuffer = true
                        NSLog("[screenaudio] first audio buffer received")
                    }
                    request?.append(boxed.buffer)
                }
            }
            engine.prepare()
            try engine.start()
            NSLog("[screenaudio] capture started (process tap)")

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

    private func teardownLocked() {
        running = false
        generation += 1
        rotationTimer?.cancel()
        rotationTimer = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        lastText = ""
        consecutiveFailures = 0
        loggedFirstBuffer = false
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
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
    }

    // MARK: Recognition with rotation (all on `queue`)

    private func startRecognitionLocked() {
        guard running else { return }
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
        let gen = generation
        recognitionTask = recognizer.recognitionTask(with: req) { @Sendable result, error in
            // Extract plain values here — SFSpeechRecognitionResult is not Sendable.
            let text = result?.bestTranscription.formattedString ?? ""
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            self.queue.async { [self] in
                guard generation == gen else { return }
                if !text.isEmpty {
                    lastText = text
                    let cb = onTranscript
                    Task { await cb?(text, isFinal) }
                }
                if failed || isFinal {
                    guard running else { return }
                    recognitionEndedLocked()
                }
            }
        }
        NSLog("[screenaudio] recognition task started (gen %d)", gen)

        rotationTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 55, repeating: 55)
        timer.setEventHandler { [self] in
            guard generation == gen, running else { return }
            rotateLocked()
        }
        rotationTimer = timer
        timer.resume()
    }

    /// Proactive rotation before the ~1-minute task lifetime kills recognition mid-sentence.
    private func rotateLocked() {
        commitLastLocked()
        generation += 1
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        consecutiveFailures = 0
        startRecognitionLocked()
    }

    /// The task died on its own (error or final) — restart it so transcription is seamless.
    private func recognitionEndedLocked() {
        commitLastLocked()
        generation += 1
        recognitionTask = nil
        request = nil
        consecutiveFailures += 1
        guard consecutiveFailures <= 5 else {
            reportError("speech recognition repeatedly failed — always-on stopped")
            teardownLocked()
            return
        }
        queue.asyncAfter(deadline: .now() + 0.5) { [self] in
            guard running else { return }
            startRecognitionLocked()
        }
    }

    private func commitLastLocked() {
        let text = lastText.trimmingCharacters(in: .whitespacesAndNewlines)
        lastText = ""
        guard !text.isEmpty, let cb = onTranscript else { return }
        NSLog("[screenaudio] committed: %@", text)
        Task { await cb(text, true) }
    }

    private func reportError(_ message: String) {
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
