import AppKit

// When relaunched under the admin password dialog this process is the root
// mount helper, not the app: run the mount sequence and exit before any
// AppKit setup.
EscalatedMount.exitIfHelperInvocation()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// LSUIElement in the bundled Info.plist hides the Dock icon; .accessory keeps
// the same behaviour when the bare binary runs during development.
app.setActivationPolicy(.accessory)
app.run()
