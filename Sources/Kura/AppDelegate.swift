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
    let viewModel = OverlayViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installHiddenEditMenu()

        panel = OverlayPanel(viewModel: viewModel)
        ThemeSampler.shared.start(panel: panel)
        if viewModel.sidebarOpen {
            panel.minSize = NSSize(width: 800, height: 300)
            panel.setContentSize(NSSize(width: 800, height: 440))
            panel.positionTopCenter()
        }
        viewModel.onSidebarResize = { [weak self] open in
            guard let panel = self?.panel else { return }
            panel.minSize = NSSize(width: open ? 800 : 480, height: 300)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().setContentSize(NSSize(width: open ? 800 : OverlayPanel.width, height: 440))
            }
            panel.positionTopCenter()
        }
        hotkeys = HotkeyManager(viewModel: viewModel, panel: panel)
        hotkeys.onToggleOverlay = { [weak self] in self?.toggleOverlay() }
        hotkeys.onSend = { [weak self] in self?.viewModel.send() }
        hotkeys.onOpenSettings = { [weak self] in self?.openSettings() }
        hotkeys.onQuit = { NSApp.terminate(nil) }
        hotkeys.onEndMeeting = { [weak self] in self?.viewModel.assist(.summarize) }
        hotkeys.register()
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
                if self?.panel.isVisible == true { self?.hideOverlay() }
            }
            return event
        }

        // First run (or after a revoked grant): onboard permissions before anything else.
        PermissionManager.shared.refresh()
        if PermissionManager.shared.requiredGranted {
            showOverlay()
        } else {
            openPermissions()
        }
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Kura Permissions"
        window.level = .statusBar
        window.sharingType = Config.debug ? .readOnly : .none
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: PermissionsView { [weak self] in
            self?.permissionsWindow?.close()
            self?.showOverlay()
        })
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
        panel.positionTopCenter()
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .kuraFocusInput, object: nil)
    }

    func hideOverlay() {
        if viewModel.status == .listening { viewModel.stopListening() }
        panel.orderOut(nil)
    }

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
        window.setContentSize(NSSize(width: 440, height: 320))
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
        window.level = .statusBar
        window.sharingType = Config.debug ? .readOnly : .none
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: SettingsView())
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 460, height: 540))
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }
}
