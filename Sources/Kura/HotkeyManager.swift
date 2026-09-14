// HotkeyManager — Carbon RegisterEventHotKey shortcuts + Right-Option hold-to-talk via global flagsChanged monitor.
import AppKit
import Carbon

@MainActor
final class HotkeyManager {
    // Set once at launch; read from C callbacks. Stable for process lifetime.
    nonisolated(unsafe) private static var active: HotkeyManager?

    private static let signature: OSType = 0x4748_5354 // 'GHST'
    private enum HotKeyID: UInt32 {
        case toggleOverlay = 1   // ⌃⌥Space
        case send = 2            // ⌃⌥Return
        case openSettings = 3    // ⌃⌥,
        case toggleListen = 4    // ⌃⌥M (toggle fallback for hold-to-talk)
        case toggleAlwaysOn = 5  // ⌃⌥L
        case quit = 6            // ⌃⌥Q
        case endMeeting = 7      // ⌃⌥E
    }

    var onToggleOverlay: (() -> Void)?
    var onSend: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var onEndMeeting: (() -> Void)?

    private let viewModel: OverlayViewModel
    private weak var panel: OverlayPanel?
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var rightOptionDown = false
    private var toggleListening = false

    init(viewModel: OverlayViewModel, panel: OverlayPanel?) {
        self.viewModel = viewModel
        self.panel = panel
        Self.active = self
    }

    func register() {
        registerCarbonHotKeys()
        installFlagsMonitor()
    }

    // MARK: Carbon hotkeys

    private func registerCarbonHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event,
                                        EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID),
                                        nil,
                                        MemoryLayout<EventHotKeyID>.size,
                                        nil,
                                        &hotKeyID)
            guard err == noErr else { return err }
            let id = hotKeyID.id
            Task { @MainActor in HotkeyManager.active?.handle(id: id) }
            return noErr
        }, 1, &spec, nil, nil)

        let mods = UInt32(controlKey | optionKey)
        let bindings: [(HotKeyID, UInt32)] = [
            (.toggleOverlay, 49), // Space
            (.send, 36),          // Return
            (.openSettings, 43),  // Comma
            (.toggleListen, 46),  // M
            (.toggleAlwaysOn, 37), // L
            (.quit, 12),           // Q
            (.endMeeting, 14),     // E
        ]
        for (hotKey, keyCode) in bindings {
            let id = EventHotKeyID(signature: Self.signature, id: hotKey.rawValue)
            var ref: EventHotKeyRef?
            RegisterEventHotKey(keyCode, mods, id, GetApplicationEventTarget(), 0, &ref)
            hotKeyRefs.append(ref)
        }
    }

    private func handle(id: UInt32) {
        guard let hotKey = HotKeyID(rawValue: id) else { return }
        switch hotKey {
        case .toggleOverlay: onToggleOverlay?()
        case .send: onSend?()
        case .openSettings: onOpenSettings?()
        case .toggleListen: toggleListen()
        case .toggleAlwaysOn:
            if panel?.isVisible != true { onToggleOverlay?() }
            viewModel.toggleAlwaysOn()
        case .quit: onQuit?()
        case .endMeeting:
            if panel?.isVisible != true { onToggleOverlay?() }
            onEndMeeting?()
        }
    }

    private func toggleListen() {
        toggleListening.toggle()
        if toggleListening {
            if panel?.isVisible != true { onToggleOverlay?() }
            viewModel.startListening()
        } else {
            viewModel.stopListening()
        }
    }

    // MARK: Hold-to-talk (Right Option, keyCode 61)

    // Listen-only CGEventTap at HID level — reliable for modifier-only holds, unlike
    // NSEvent global monitors which silently drop flagsChanged on modern macOS.
    private var eventTap: CFMachPort?

    private func installFlagsMonitor() {
        let mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, _ -> Unmanaged<CGEvent>? in
                guard type == .flagsChanged,
                      event.getIntegerValueField(.keyboardEventKeycode) == 61 else {
                    return Unmanaged.passUnretained(event)
                }
                let down = event.flags.contains(.maskAlternate)
                Task { @MainActor in HotkeyManager.active?.rightOptionChanged(down: down) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            // Typing and the visible dictation button remain available without global hold-to-talk.
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)!
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func rightOptionChanged(down: Bool) {
        guard down != rightOptionDown else { return }
        rightOptionDown = down
        if down {
            if panel?.isVisible != true { onToggleOverlay?() }
            viewModel.startListening()
        } else if viewModel.status == .listening {
            viewModel.stopListening()
        }
    }
}
