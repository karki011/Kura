// Permissions — first-run onboarding: check/request mic + speech + accessibility, deep links to System Settings.
import SwiftUI
import AppKit
import AVFoundation
import Speech
import ApplicationServices

enum KuraPermission: CaseIterable, Identifiable {
    case microphone, speech, accessibility, screenRecording
    var id: Self { self }

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .speech: return "Speech Recognition"
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        }
    }

    var detail: String {
        switch self {
        case .microphone: return "Dictation and optional own-voice capture"
        case .speech: return "Apple transcription and dictation; not needed for local system audio"
        case .accessibility: return "Recommended — hold-to-talk from any app"
        case .screenRecording: return "Optional — observe a selected meeting window"
        }
    }

    var icon: String {
        switch self {
        case .microphone: return "mic.fill"
        case .speech: return "waveform"
        case .accessibility: return "hand.raised.fill"
        case .screenRecording: return "rectangle.dashed.badge.record"
        }
    }

    var settingsURL: URL {
        let pane: String
        switch self {
        case .microphone: pane = "Privacy_Microphone"
        case .speech: pane = "Privacy_SpeechRecognition"
        case .accessibility: pane = "Privacy_Accessibility"
        case .screenRecording: pane = "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

struct PermissionStatusView: View {
    @ObservedObject private var manager = PermissionManager.shared
    var body: some View {
        WorkspaceSection("Permissions on this Mac") {
            Text("Checked for this running copy of Kura. A rebuild or a macOS permission change may require granting access again and restarting Kura.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(KuraPermission.allCases) { permission in
                HStack(spacing: 10) {
                    Image(systemName: permission.icon).frame(width: 22).foregroundStyle(KuraStyle.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(permission.title).font(.callout.weight(.medium))
                        Text(permission.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(manager.isGranted(permission) ? "Granted" : "Not granted").font(.caption)
                        .foregroundStyle(manager.isGranted(permission) ? KuraStyle.accent : .orange)
                    if !manager.isGranted(permission) {
                        Button("Grant access…") { manager.requestAndOpen(permission) }.controlSize(.small)
                    }
                }.padding(.vertical, 6)
            }
            Divider()
            Label("System audio · verify with Listen", systemImage: "speaker.wave.2.fill").font(.callout.weight(.medium))
            Text("System-audio recording is separate from microphone and screen access. Kura cannot reliably preflight the process-tap grant: play spoken audio and check the live level meter. If it stays still, enable Kura in Screen & System Audio Recording, then quit and reopen this copy of the app.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Open audio recording permissions…") { manager.openSettings(.screenRecording) }
            Button("Refresh status") { manager.refresh() }
        }
        .task {
            while !Task.isCancelled {
                manager.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
}

@MainActor
final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    @Published var mic: AVAuthorizationStatus = .notDetermined
    @Published var speech: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    @Published var accessibility = false
    @Published var screenRecording = false

    var requiredGranted: Bool { mic == .authorized && speech == .authorized }

    func refresh() {
        mic = AVCaptureDevice.authorizationStatus(for: .audio)
        speech = SFSpeechRecognizer.authorizationStatus()
        accessibility = AXIsProcessTrusted()
        screenRecording = CGPreflightScreenCaptureAccess()
    }

    func isGranted(_ p: KuraPermission) -> Bool {
        switch p {
        case .microphone: return mic == .authorized
        case .speech: return speech == .authorized
        case .accessibility: return accessibility
        case .screenRecording: return screenRecording
        }
    }

    // Ask everything in one pass: fires the system prompts for anything still undetermined.
    // Handlers are invoked by TCC on a background thread — closures must be nonisolated.
    func requestAll() {
        if mic == .notDetermined {
            Task { @Sendable in
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                self.refresh()
            }
        }
        if speech == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { @Sendable _ in
                Task { @MainActor in self.refresh() }
            }
        }
        if !accessibility {
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        if !screenRecording {
            _ = CGRequestScreenCaptureAccess()
        }
        refresh()
    }

    func openSettings(_ p: KuraPermission) {
        NSWorkspace.shared.open(p.settingsURL)
    }

    // Trigger the TCC request (so the app appears in the pane), then open it.
    func requestAndOpen(_ p: KuraPermission) {
        switch p {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in self.refresh() } }
        case .speech:
            SFSpeechRecognizer.requestAuthorization { @Sendable _ in Task { @MainActor in self.refresh() } }
        case .accessibility:
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .screenRecording:
            CGRequestScreenCaptureAccess()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.openSettings(p)
        }
    }
}

struct PermissionsView: View {
    @ObservedObject var manager = PermissionManager.shared
    var onContinue: () -> Void
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Kura needs a few permissions")
                .font(.headline)
            Text("Grant these once — macOS remembers them for this app.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(KuraPermission.allCases) { p in
                HStack(spacing: 10) {
                    Image(systemName: p.icon)
                        .frame(width: 20)
                        .foregroundStyle(manager.isGranted(p) ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title).font(.system(size: 13, weight: .medium))
                        Text(p.detail).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if manager.isGranted(p) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open Settings") { manager.requestAndOpen(p) }
                            .controlSize(.small)
                            .pointingHandCursor()
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25)))
            }

            HStack {
                Button("Ask macOS to prompt me") { manager.requestAll() }
                    .controlSize(.small)
                    .pointingHandCursor()
                Spacer()
                Button("Continue") { onContinue() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!manager.requiredGranted)
                    .pointingHandCursor(enabled: manager.requiredGranted)
            }
        }
        .padding(16)
        .frame(width: 400)
        .preferredColorScheme(.dark)
        .onAppear {
            manager.refresh()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Task { @MainActor in manager.refresh() }
            }
        }
        .onDisappear { pollTimer?.invalidate(); pollTimer = nil }
    }
}

extension Notification.Name {
    static let kuraOpenPermissions = Notification.Name("kuraOpenPermissions")
}
