// AppDelegate — wires up panel, hotkeys, settings; keeps app alive with no visible windows.
import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: OverlayPanel!
    private var hotkeys: HotkeyManager!
    private var settingsWindow: NSWindow?
    private var permissionsWindow: NSWindow?
    private var contextWindow: NSWindow?
    private var escapeMonitor: Any?
    private var statusItem: NSStatusItem?
    private var restartRequested = false
    let viewModel = Config.preview ? PreviewFixtures.model() : OverlayViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(Config.debug ? .regular : .accessory)
        installHiddenEditMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.bubble", accessibilityDescription: "Kura")
        let menu = NSMenu()
        let show = menu.addItem(withTitle: "Show Kura", action: #selector(showFromMenu), keyEquivalent: "")
        show.target = self
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(settingsFromMenu), keyEquivalent: "")
        settings.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Kura", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        item.menu = menu; statusItem = item

        panel = OverlayPanel(viewModel: viewModel)
        switch viewModel.viewMode {
        case .icon:
            panel.minSize = NSSize(width: 240, height: 120)
            panel.setContentSize(NSSize(width: 300, height: 170))
        case .compact:
            panel.minSize = NSSize(width: 540, height: 360)
            panel.setContentSize(NSSize(width: 560, height: 400))
        case .full:
            if viewModel.sidebarOpen {
                panel.minSize = NSSize(width: 900, height: 600)
                if !panel.setFrameUsingName("KuraWorkspace") { panel.setContentSize(NSSize(width: 1000, height: 720)); panel.positionTopCenter() }
            }
        }
        viewModel.onSidebarResize = { [weak self] open in
            guard let self, self.viewModel.viewMode == .full, let panel = self.panel else { return }
            panel.minSize = NSSize(width: open ? 900 : 680, height: 600)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
                panel.animator().setContentSize(NSSize(width: open ? 1000 : 760, height: max(600, panel.frame.height)))
            }
        }
        viewModel.onViewModeResize = { [weak self] mode in
            guard let self, let panel = self.panel else { return }
            switch mode {
            case .icon:
                panel.minSize = NSSize(width: 240, height: 120)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
                    panel.animator().setContentSize(NSSize(width: 300, height: 170))
                }
            case .compact:
                panel.minSize = NSSize(width: 540, height: 360)
                panel.setContentSize(NSSize(width: 560, height: 400))
            case .full:
                let open = self.viewModel.sidebarOpen
                panel.minSize = NSSize(width: open ? 900 : 680, height: 600)
                panel.setContentSize(NSSize(width: open ? 1000 : 760, height: max(600, panel.frame.height)))
            }
        }
        hotkeys = HotkeyManager(viewModel: viewModel, panel: panel)
        hotkeys.onToggleOverlay = { [weak self] in self?.toggleOverlay() }
        hotkeys.onSend = { [weak self] in self?.viewModel.send() }
        hotkeys.onOpenSettings = { [weak self] in self?.openSettings() }
        hotkeys.onQuit = { NSApp.terminate(nil) }
        hotkeys.onEndMeeting = { [weak self] in self?.viewModel.assist(.summarize) }
        if !Config.preview { hotkeys.register() }
        NotificationCenter.default.addObserver(forName: .kuraOpenSettings, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.openSettings() }
        }
        NotificationCenter.default.addObserver(forName: .kuraOpenPermissions, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.openPermissions() }
        }
        NotificationCenter.default.addObserver(forName: .kuraOpenContext, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.openContext() }
        }

        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor in
                if self?.panel.isVisible == true, self?.panel.attachedSheet == nil { self?.hideOverlay() }
            }
            return event
        }

        // First run (or after a revoked grant): onboard permissions before anything else.
        // Deferred a runloop turn: windows ordered in from didFinishLaunching can
        // stay invisible even though they exist and report as focused.
        PermissionManager.shared.refresh()
        if !Config.preview && !PermissionManager.shared.requiredGranted {
            DispatchQueue.main.async { self.openPermissions() }
        } else { showOverlay() }
    }

    // Text-field ⌘C/⌘V/⌘X/⌘A are dispatched via the main menu's key equivalents.
    // Accessory apps show no menu bar, so this menu is invisible but restores the shortcuts.
    private func installHiddenEditMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        NSApp.mainMenu = mainMenu
    }

    func openPermissions() {
        if let w = permissionsWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }
        // Agent apps can't reliably order a titled window in from a cold,
        // inactive launch. Become a regular app while the wizard is up;
        // accessory policy returns when the window closes.
        if !Config.debug { NSApp.setActivationPolicy(.regular) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Kura"
        window.level = .statusBar
        window.sharingType = Config.debug ? .readOnly : .none
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: OnboardingView { [weak self] in
            self?.permissionsWindow?.close()
            self?.showOverlay()
        })
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in
                if self?.panel.isVisible == false && !Config.debug { NSApp.setActivationPolicy(.accessory) }
            }
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        permissionsWindow = window
    }

    func toggleOverlay() {
        if panel.isVisible { hideOverlay() } else { showOverlay() }
    }

    func showOverlay() {
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) { panel.positionTopCenter() }
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .kuraFocusInput, object: nil)
    }

    func hideOverlay() {
        if viewModel.status == .listening { viewModel.stopListening() }
        panel.orderOut(nil)
    }
    @objc private func showFromMenu() { showOverlay() }
    @objc private func settingsFromMenu() { openSettings() }

    func openContext() {
        if let w = contextWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Session Context"
        window.level = .statusBar
        window.sharingType = Config.debug ? .readOnly : .none
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: ContextView(viewModel: viewModel) { [weak self] in
            self?.contextWindow?.close()
        })
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 614, height: 600))
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        contextWindow = window
    }

    func openSettings() {
        if let w = settingsWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Kura Settings"
        window.styleMask.insert(.resizable)
        window.minSize = NSSize(width: 500, height: 540)
        window.level = .statusBar
        window.sharingType = Config.debug ? .readOnly : .none
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: SettingsView())
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 580, height: 720))
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    func requestRestart() {
        restartRequested = true
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        viewModel.stopAnswer(); viewModel.stopListening(); viewModel.stopCapture()
        Task {
            do {
                try await viewModel.prepareToQuit()
                if restartRequested {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.createsNewApplicationInstance = true
                    _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
                }
                sender.reply(toApplicationShouldTerminate: true)
            }
            catch {
                restartRequested = false
                viewModel.lastError = "Could not save before quitting: \(error.localizedDescription). Please retry after resolving the save error."
                showOverlay(); sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
