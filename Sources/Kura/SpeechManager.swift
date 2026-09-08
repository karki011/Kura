// SpeechManager — push-to-talk: AVAudioEngine mic → SFSpeechRecognizer, partial results stream live.
import AVFoundation
@preconcurrency import Speech

@MainActor
final class SpeechManager {
    var onPartialResult: (@MainActor (String) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    var onFinalResult: (@MainActor (String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var running = false
    private var startTask: Task<Void, Never>?
    private var generation = UUID()
    private var tapInstalled = false
    private var continuous = false
    private var rotationTask: Task<Void, Never>?
    private var lastText = ""

    func startContinuous() { continuous = true; start() }

    func start() {
        guard !running, startTask == nil else { return }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let speech = SFSpeechRecognizer.authorizationStatus()
        if mic == .denied || mic == .restricted || speech == .denied || speech == .restricted {
            NotificationCenter.default.post(name: .kuraOpenPermissions, object: nil)
            onError?("mic/speech permission denied (mic=\(mic.rawValue) speech=\(speech.rawValue))")
            return
        }
        generation = UUID(); let token = generation
        startTask = Task {
            let granted = await self.requestAuthorizations()
            guard !Task.isCancelled, self.generation == token else { return }
            self.startTask = nil
            guard granted else {
                self.onError?("authorization request returned not-granted")
                return
            }
            self.beginCapture()
        }
    }

    // Must stay nonisolated: Speech/TCC invoke these handlers on a background XPC
    // thread, and a MainActor-isolated closure traps there under Swift 6.
    nonisolated private func requestAuthorizations() async -> Bool {
        let speech = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                cont.resume(returning: status)
            }
        }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        return speech == .authorized && mic
    }

    func stop() {
        if continuous && !lastText.isEmpty { onFinalResult?(lastText) }
        lastText = ""; continuous = false; rotationTask?.cancel(); rotationTask = nil
        generation = UUID(); startTask?.cancel(); startTask = nil
        running = false
        audioEngine.stop()
        if tapInstalled { audioEngine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio()
        request = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func beginCapture() {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            onError?("speech recognizer unavailable")
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        req.shouldReportPartialResults = true
        request = req

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            req.append(buffer)
        }
        tapInstalled = true

        let token = generation
        recognitionTask = recognizer.recognitionTask(with: req) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failure = error?.localizedDescription
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if let text { self.lastText = text; self.onPartialResult?(text) }
                if final || failure != nil {
                    let restart = self.continuous && failure == nil
                    self.stop()
                    if let failure, !failure.lowercased().contains("cancel") { self.onError?("Recognition failed: \(failure)") }
                    if restart { self.startContinuous() }
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            running = true
            if continuous {
                rotationTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(50)) } catch { return }
                    guard let self, self.generation == token, self.continuous else { return }
                    self.stop(); self.startContinuous()
                }
            }
        } catch {
            stop()
            onError?("audio engine start failed: \(error.localizedDescription)")
        }
    }
}
