// Onboarding — Shadow-style first-run wizard: one permission per screen, system prompt
// when possible, annotated guide when the user must flip a settings toggle, live
// grant detection with auto-advance. Also serves as the permission repair surface.
import SwiftUI
import AppKit

struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, microphone, speech, accessibility, screenAudio, done
        var permission: KuraPermission? {
            switch self {
            case .microphone: return .microphone
            case .speech: return .speech
            case .accessibility: return .accessibility
            case .screenAudio: return .screenRecording
            case .welcome, .done: return nil
            }
        }
        var next: Step { Step(rawValue: rawValue + 1) ?? .done }
    }

    @ObservedObject private var manager = PermissionManager.shared
    var onContinue: () -> Void
    @State private var step: Step = .welcome
    @State private var advancing = false
    @State private var guideShown = false
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            content.frame(maxHeight: .infinity)
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 520, height: 540)
        .modifier(KuraAppearance())
        .onAppear { startPolling() }
        .onDisappear { pollTimer?.invalidate(); pollTimer = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            manager.refresh(); advanceIfGranted()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            KuraLogo(size: 26)
            Text("Welcome to Kura").font(.system(size: 15, weight: .semibold, design: .rounded))
            Spacer()
            HStack(spacing: 6) {
                ForEach([Step.microphone, .speech, .accessibility, .screenAudio], id: \.rawValue) { s in
                    Circle()
                        .fill(dotColor(for: s))
                        .frame(width: 7, height: 7)
                }
            }
        }.padding(16)
    }
    private func dotColor(for s: Step) -> Color {
        if let p = s.permission, manager.isGranted(p) { return KuraStyle.accent }
        return s == step ? KuraStyle.accent.opacity(0.45) : Color.primary.opacity(0.15)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .microphone: permissionStep(.microphone,
            why: "Dictate questions and, if you enable it, include your own voice in meeting notes.",
            promptLabel: "Allow microphone access")
        case .speech: permissionStep(.speech,
            why: "Apple's on-device speech recognition turns meeting audio into a live transcript.",
            promptLabel: "Allow speech recognition")
        case .accessibility: permissionStep(.accessibility,
            why: "Recommended — hold-to-talk from any app, and reading speaker names from your meeting app without screenshots.",
            promptLabel: "Open Accessibility settings",
            optional: true, guide: true)
        case .screenAudio: permissionStep(.screenRecording,
            why: "Lets Kura hear meeting audio and, optionally, observe a meeting window as a fallback for name cues. macOS may ask you to quit and reopen Kura afterwards — that's normal.",
            promptLabel: "Open Screen & System Audio settings",
            optional: true, guide: true)
        case .done: done
        }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "waveform.bubble.fill").font(.system(size: 40)).foregroundStyle(KuraStyle.accent)
            Text("Four one-time grants.\nAbout a minute.").font(.system(size: 22, weight: .semibold, design: .rounded)).multilineTextAlignment(.center)
            Text("Kura listens so you don't have to take notes. macOS will ask you directly — we'll show you exactly where each switch is.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }.padding(.horizontal, 48)
    }

    private func permissionStep(_ p: KuraPermission, why: String, promptLabel: String, optional: Bool = false, guide: Bool = false) -> some View {
        let granted = manager.isGranted(p)
        return VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: p.icon).font(.system(size: 30)).foregroundStyle(granted ? KuraStyle.accent : Color.secondary)
            Text(p.title).font(.system(size: 19, weight: .semibold, design: .rounded))
            Text(why).font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(KuraStyle.accent).font(.callout.weight(.medium))
            } else if guide || isDenied(p) {
                SettingsGuide(appName: "Kura").padding(.top, 2)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 40)
        .id(step)
    }

    private var done: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: manager.requiredGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 34)).foregroundStyle(manager.requiredGranted ? KuraStyle.accent : .orange)
            Text(manager.requiredGranted ? "You're set." : "Almost there.").font(.system(size: 20, weight: .semibold, design: .rounded))
            VStack(spacing: 6) {
                ForEach(KuraPermission.allCases) { p in
                    HStack(spacing: 8) {
                        Image(systemName: manager.isGranted(p) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(manager.isGranted(p) ? KuraStyle.accent : Color.secondary)
                        Text(p.title).font(.callout)
                        Spacer()
                        if !manager.isGranted(p) {
                            Button("Fix") { step = step(for: p) }.controlSize(.small).buttonStyle(KuraChipButtonStyle())
                        }
                    }
                }
            }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            Text("Reopen this guide anytime from Settings → Permissions.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(.horizontal, 48)
    }
    private func step(for p: KuraPermission) -> Step {
        switch p {
        case .microphone: return .microphone
        case .speech: return .speech
        case .accessibility: return .accessibility
        case .screenRecording: return .screenAudio
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome && step != .done {
                Button("Back") { withAnimation { step = Step(rawValue: step.rawValue - 1) ?? .welcome } }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Spacer()
            footerPrimary
        }.padding(16)
    }
    @ViewBuilder private var footerPrimary: some View {
        switch step {
        case .welcome:
            Button("Get started") { withAnimation { step = .microphone } }
                .buttonStyle(.borderedProminent).controlSize(.large).pointingHandCursor()
        case .done:
            Button("Start using Kura") { onContinue() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!manager.requiredGranted)
                .pointingHandCursor(enabled: manager.requiredGranted)
        default:
            let p = step.permission!
            let granted = manager.isGranted(p)
            HStack(spacing: 12) {
                if step == .accessibility || step == .screenAudio {
                    Button(granted ? "Continue" : "Skip for now") { advance() }
                        .buttonStyle(.plain).foregroundStyle(.secondary).pointingHandCursor()
                }
                if !granted {
                    Button(buttonLabel(for: p)) { primaryAction(p) }
                        .buttonStyle(.borderedProminent).controlSize(.large).pointingHandCursor()
                }
            }
        }
    }
    private func buttonLabel(for p: KuraPermission) -> String {
        switch p {
        case .microphone: return isDenied(p) ? "Open Microphone settings" : "Allow microphone access"
        case .speech: return isDenied(p) ? "Open Speech settings" : "Allow speech recognition"
        case .accessibility: return "Open Accessibility settings"
        case .screenRecording: return "Open Screen & System Audio settings"
        }
    }
    private func isDenied(_ p: KuraPermission) -> Bool {
        switch p {
        case .microphone: return manager.mic == .denied || manager.mic == .restricted
        case .speech: return manager.speech == .denied || manager.speech == .restricted
        default: return false
        }
    }
    private func primaryAction(_ p: KuraPermission) {
        switch p {
        case .microphone, .speech:
            if isDenied(p) { manager.openSettings(p) } else { manager.request(p) }
        case .accessibility:
            manager.preseedAccessibility()
            manager.requestAndOpen(p)
        case .screenRecording:
            manager.requestAndOpen(p)
        }
    }

    private func advance() { withAnimation { step = step.next } }
    private func advanceIfGranted() {
        guard !advancing, let p = step.permission, manager.isGranted(p) else { return }
        advancing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            withAnimation { self.step = self.step.next }
            self.advancing = false
        }
    }
    private func startPolling() {
        manager.refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                manager.refresh()
                advanceIfGranted()
            }
        }
    }
}

/// Annotated replica of the settings list the user is about to see — the
/// "watch where the app goes" moment: Kura's row is highlighted with the
/// toggle to flip. Rendered in our own window; macOS allows no overlay on
/// System Settings itself.
private struct SettingsGuide: View {
    let appName: String
    @State private var pulse = false
    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 0) {
                guideRow(icon: "app.fill", name: "Some Other App", enabled: false)
                Divider().padding(.leading, 34)
                guideRow(icon: nil, name: appName, enabled: true)
                    .background(KuraStyle.accent.opacity(pulse ? 0.18 : 0.08))
                Divider().padding(.leading, 34)
                guideRow(icon: "app.fill", name: "Another App", enabled: false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(KuraStyle.accent.opacity(pulse ? 0.7 : 0.3), lineWidth: 1.5))
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            Label("Find \(appName) in the list and switch it on", systemImage: "arrow.up.left.and.arrow.down.right")
                .font(.caption).foregroundStyle(KuraStyle.accent)
        }
        .onAppear { pulse = true }
    }
    private func guideRow(icon: String?, name: String, enabled: Bool) -> some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary) }
            else { KuraLogo(size: 18) }
            Text(name).font(.system(size: 12))
            Spacer()
            Capsule().fill(enabled ? KuraStyle.accent : Color.primary.opacity(0.2))
                .frame(width: 26, height: 15)
                .overlay(alignment: enabled ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 12, height: 12).padding(1.5)
                }
        }.padding(.horizontal, 10).padding(.vertical, 7)
    }
}
