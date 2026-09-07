// Config — launch flags. --debug (or KURA_DEBUG=1): normal app, capturable windows, diagnostics line.
import Foundation
import AppKit

enum Config {
    static let debug = CommandLine.arguments.contains("--debug")
        || ProcessInfo.processInfo.environment["KURA_DEBUG"] == "1"
        || UserDefaults.standard.bool(forKey: "debugMode")
}

@MainActor
func restartApp() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-n", Bundle.main.bundleURL.path]
    try? task.run()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        NSApp.terminate(nil)
    }
}
