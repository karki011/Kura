// SpeechManager — push-to-talk: AVAudioEngine mic → SFSpeechRecognizer, partial results stream live.
import AVFoundation
@preconcurrency import Speech

@MainActor
final class SpeechManager {
    var onPartialResult: (@MainActor (String) -> Void)?
    var onError: (@MainActor (String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var running = false

    func start() {
        guard !running else { return }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let speech = SFSpeechRecognizer.authorizationStatus()
        if mic == .denied || mic == .restricted || speech == .denied || speech == .restricted {
            NotificationCenter.default.post(name: .kuraOpenPermissions, object: nil)
            onError?("mic/speech permission denied (mic=\(mic.rawValue) speech=\(speech.rawValue))")
            return
        }
        Task {
            let granted = await self.requestAuthorizations()
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
        guard running else { return }
        running = false
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
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

        let onPartial = onPartialResult
        let onErr = onError
        let onStop: @MainActor () -> Void = { [weak self] in self?.stop() }
        recognitionTask = recognizer.recognitionTask(with: req) { @Sendable result, error in
            if let text = result?.bestTranscription.formattedString {
                Task { await onPartial?(text) }
            }
            if let error, !(error as NSError).localizedDescription.lowercased().contains("cancel") {
                Task { await onErr?("recognition failed: \((error as NSError).localizedDescription)") }
            }
            if error != nil || (result?.isFinal ?? false) {
                Task { await onStop() }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            running = true
        } catch {
            stop()
            onError?("audio engine start failed: \(error.localizedDescription)")
        }
    }
}
