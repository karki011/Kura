import Foundation
import SwiftUI
import AppKit

struct CaptureDiagnosticSnapshot: Equatable, Sendable {
    var phase = "Not started"
    var buffers = 0
    var rejectedBuffers = 0
    var peakLevel = 0.0
    var recognitionResults = 0
    var lastIssue = "None"
    var report: String {
        "Stage: \(phase)\nAudio buffers: \(buffers)\nRejected buffers: \(rejectedBuffers)\nPeak audio level: \(String(format: "%.4f", peakLevel))\nRecognition results: \(recognitionResults)\nLast issue: \(lastIssue)"
    }
}

// Independent of the audio queue: status remains readable if a macOS call hangs.
final class CaptureDiagnostics: @unchecked Sendable {
    static let shared = CaptureDiagnostics()
    private let lock = NSLock()
    private var value = CaptureDiagnosticSnapshot()
    var snapshot: CaptureDiagnosticSnapshot { lock.withLock { value } }
    func reset() { lock.withLock { value = CaptureDiagnosticSnapshot() } }
    func stage(_ phase: String) { lock.withLock { value.phase = phase } }
    func buffer(level: Double) { lock.withLock { value.buffers += 1; value.peakLevel = max(value.peakLevel, level) } }
    func reject(_ reason: String) { lock.withLock { value.rejectedBuffers += 1; value.lastIssue = reason } }
    func recognitionResult() { lock.withLock { value.recognitionResults += 1 } }
    func issue(_ reason: String) { lock.withLock { value.lastIssue = reason } }
}

struct CaptureDiagnosticsView: View {
    @State private var snapshot = CaptureDiagnostics.shared.snapshot
    var body: some View {
        WorkspaceSection("Live capture diagnostics") {
            Text(snapshot.report).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text("Start Listen, then play spoken audio. Zero buffers means capture has not delivered audio. Buffers with a near-zero peak suggest silence. A nonzero peak with no recognition results points to transcription. This report contains no transcript text or API keys.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Copy diagnostic report") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("Kura \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development")\nApp: \(Bundle.main.bundlePath)\n\(snapshot.report)", forType: .string)
            }
        }.task {
            while !Task.isCancelled {
                snapshot = CaptureDiagnostics.shared.snapshot
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
}
