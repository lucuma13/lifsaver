import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// LSUIElement in the bundled Info.plist hides the Dock icon; .accessory keeps
// the same behaviour when the bare binary runs during development.
app.setActivationPolicy(.accessory)
app.run()
