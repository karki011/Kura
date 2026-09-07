// Kura — calm live context for conversations. Entry point.
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(Config.debug ? .regular : .accessory)
app.run()
