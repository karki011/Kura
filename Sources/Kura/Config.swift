// Config — launch flags. --debug (or KURA_DEBUG=1): normal app, capturable windows, diagnostics line.
import Foundation
import AppKit

enum Config {
    static let preview = Bundle.main.bundleIdentifier?.hasSuffix(".preview") == true
    static let debug = preview || CommandLine.arguments.contains("--debug")
        || ProcessInfo.processInfo.environment["KURA_DEBUG"] == "1"
        || UserDefaults.standard.bool(forKey: "debugMode")
}

@MainActor
func restartApp() {
    (NSApp.delegate as? AppDelegate)?.requestRestart()
}
