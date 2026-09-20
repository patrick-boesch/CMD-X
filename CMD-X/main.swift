import AppKit

NSLog("[CMD-X] entry point reached; creating NSApplication")
let application = NSApplication.shared
NSLog("[CMD-X] NSApplication created; creating delegate")
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
NSLog("[CMD-X] delegate installed; entering application run loop")
// NSApplication.delegate is weak. Keep our delegate alive for the entire run.
withExtendedLifetime(delegate) {
    application.run()
}
NSLog("[CMD-X] application run loop ended")
