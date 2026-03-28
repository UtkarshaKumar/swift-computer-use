import Foundation
import AppKit
import SDDCore

// SDD requires a running NSApplication for NSWorkspace notifications and
// the main run loop for AXObserver run-loop sources.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // Background daemon — no Dock icon

// MARK: - Daemon bootstrap

let manager = AXObserverManager()

manager.eventHandler = { (event: AXEvent) in
    // TODO(Phase 1): forward to WorldModel.apply(event:)
    // For now, log to stderr for CLI verification.
    fputs("[\(ISO8601DateFormatter().string(from: event.timestamp))] \(event.notification.rawValue)\n", stderr)
}

// Check accessibility permission before starting
let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
guard AXIsProcessTrustedWithOptions(options) else {
    fputs("sdd: Accessibility permission required. Grant access in System Settings → Privacy & Security → Accessibility.\n", stderr)
    exit(1)
}

manager.start()

// Keep the daemon alive on the main run loop
RunLoop.main.run()
