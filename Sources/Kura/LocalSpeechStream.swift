import Foundation

struct SpeakerSegment: Codable, Equatable, Sendable {
    var speaker: Int
    var text: String
    var start: Double
}

struct LocalSpeechConfiguration: Sendable {
    var python: String
    var whisper: String
    var whisperModel: String
    var speakerModel: String
    static var saved: Self {
        let d = UserDefaults.standard
        return Self(python: d.string(forKey: "localSpeechPython") ?? "", whisper: d.string(forKey: "localWhisperCLI") ?? "",
                    whisperModel: d.string(forKey: "localWhisperModel") ?? "", speakerModel: d.string(forKey: "localSpeakerModel") ?? "")
    }
    func validate() throws {
        let fm = FileManager.default
        for (name, path) in [("Python", python), ("whisper-cli", whisper)] {
            guard path.hasPrefix("/"), fm.isExecutableFile(atPath: path) else { throw KuraError.message("Choose an installed \(name) executable in Settings → Audio.") }
        }
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: whisperModel, isDirectory: &directory), !directory.boolValue else { throw KuraError.message("Choose a downloaded Whisper .bin model in Settings → Audio.") }
        guard fm.fileExists(atPath: speakerModel + "/config.yaml") else { throw KuraError.message("Choose the downloaded pyannote Community-1 folder containing config.yaml in Settings → Audio.") }
    }
    static func resource(_ name: String) -> URL {
        let bundled = Bundle.main.resourceURL!.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources").appendingPathComponent(name)
    }
}

enum LocalSpeechParser {
    static func segments(_ data: Data) throws -> [SpeakerSegment] {
        struct Response: Decodable { var segments: [SpeakerSegment]?; var error: String? }
        let response = try JSONDecoder().decode(Response.self, from: data)
        if let error = response.error { throw KuraError.message(error) }
        return (response.segments ?? []).filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.start.isFinite && $0.start >= 0 }
    }
}

/// All state is confined to queue. A single offline worker preserves speaker matching
/// across overlapping 30-second windows. Audio is temporary and removed after processing.
final class LocalSpeechStream: @unchecked Sendable {
    private let queue = DispatchQueue(label: "kura.local-speech")
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let root: URL
    private let sampleRate: Double
    private let onSegments: @Sendable ([SpeakerSegment]) -> Void
    private let onError: @Sendable (String) -> Void
    private var pcm = Data(), incoming = Data()
    private var totalSamples = 0, submittedSamples = 0, pending = 0
    private var closed = false, finished = false
    private var completion: (@Sendable () -> Void)?
    private var watchdog: DispatchWorkItem?

    init(configuration: LocalSpeechConfiguration, sampleRate: Double, workerURL: URL = LocalSpeechConfiguration.resource("local_speech.py"), onSegments: @escaping @Sendable ([SpeakerSegment]) -> Void,
         onError: @escaping @Sendable (String) -> Void) throws {
        try configuration.validate()
        self.sampleRate = sampleRate; self.onSegments = onSegments; self.onError = onError
        root = FileManager.default.temporaryDirectory.appendingPathComponent("KuraLocalAudio-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        process.executableURL = URL(fileURLWithPath: configuration.python)
        process.arguments = ["-u", workerURL.path, configuration.whisper, configuration.whisperModel, configuration.speakerModel]
        var environment = ProcessInfo.processInfo.environment
        for key in ["HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_HUB_DISABLE_TELEMETRY"] { environment[key] = "1" }
        environment["PYANNOTE_METRICS_ENABLED"] = "0"
        process.environment = environment
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice // Never log transcripts or audio paths.
        output.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            self.queue.async { self.receive(data) }
        }
        do { try process.run() }
        catch { output.fileHandleForReading.readabilityHandler = nil; try? FileManager.default.removeItem(at: root); throw error }
    }

    func send(_ data: Data) {
        queue.async { [self] in
            guard !closed else { return }
            pcm.append(data); totalSamples += data.count / 2
            let limit = Int(sampleRate * 30) * 2
            if pcm.count > limit { pcm.removeFirst(pcm.count - limit) }
            if totalSamples - submittedSamples >= Int(sampleRate * 10) { submit() }
        }
    }
    private func submit() {
        guard totalSamples > submittedSamples else { return }
        guard pending < 2 else { fail("Local speech cannot keep up with the audio. Try a smaller Whisper model or Apple transcription."); return }
        do {
            let file = root.appendingPathComponent("\(totalSamples).wav")
            try Self.wav(pcm, sampleRate: UInt32(sampleRate)).write(to: file, options: .atomic)
            let request: [String: Any] = ["file": file.path, "offset": Double(totalSamples - pcm.count / 2) / sampleRate,
                                         "cutoff": Double(submittedSamples) / sampleRate]
            var line = try JSONSerialization.data(withJSONObject: request); line.append(10)
            try input.fileHandleForWriting.write(contentsOf: line)
            submittedSamples = totalSamples; pending += 1
            if watchdog == nil { armWatchdog() }
        } catch { fail("Local speech input failed: \(error.localizedDescription)") }
    }
    private func armWatchdog() {
        let timer = DispatchWorkItem { [weak self] in self?.fail("Local speech timed out. Check the Python environment and downloaded models in Settings → Audio.") }
        watchdog = timer; queue.asyncAfter(deadline: .now() + 120, execute: timer)
    }
    private func receive(_ data: Data) {
        guard !finished else { return }
        if data.isEmpty {
            if !closed || pending > 0 { onError("Local speech worker stopped before finishing. Check pyannote.audio and both local models in Settings → Audio.") }
            finish(); return
        }
        incoming.append(data)
        guard incoming.count < 2_000_000 else { fail("Invalid output from local speech worker."); return }
        while let newline = incoming.firstIndex(of: 10) {
            let line = Data(incoming[..<newline]); incoming.removeSubrange(...newline)
            do {
                let segments = try LocalSpeechParser.segments(line)
                pending = max(0, pending - 1)
                watchdog?.cancel(); watchdog = nil
                if pending > 0 { armWatchdog() }
                onSegments(segments)
            } catch { fail("Local speech: \(error.localizedDescription)"); return }
        }
    }
    func stop(completion: @escaping @Sendable () -> Void = {}) {
        queue.async { [self] in
            if finished { completion(); return }
            self.completion = completion
            if !closed { submit(); closed = true; try? input.fileHandleForWriting.close() }
            if !finished && watchdog == nil { armWatchdog() }
            if finished { self.completion?(); self.completion = nil }
        }
    }
    private func fail(_ message: String) { guard !finished else { return }; onError(message); finish() }
    private func finish() {
        guard !finished else { return }
        closed = true; finished = true; watchdog?.cancel(); watchdog = nil
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: root)
        pcm = Data(); completion?(); completion = nil
    }
    static func wav(_ pcm: Data, sampleRate: UInt32) -> Data {
        var data = Data("RIFF".utf8)
        func put<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        put(UInt32(pcm.count + 36)); data.append(Data("WAVEfmt ".utf8)); put(UInt32(16))
        put(UInt16(1)); put(UInt16(1)); put(sampleRate); put(sampleRate * 2); put(UInt16(2)); put(UInt16(16))
        data.append(Data("data".utf8)); put(UInt32(pcm.count)); data.append(pcm); return data
    }
}
