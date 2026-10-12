// VibeCat: a tiny desktop cat that tells you what Claude Code is doing.
// Build: swiftc -O Sources/*.swift -o vibecat    Run: ./vibecat    Self-check: ./vibecat --test
// Reads events that hook.sh appends to ~/.vibecat/events.jsonl, and plan usage that statusline.sh saves to ~/.vibecat/usage.json.
// Click the cat for its menu (usage meters, last message, minimise, face-only, mute, quit). Minimised, it sits quietly; click to wake.
// Bubbles close with their x, or by hovering them. Click a "Needs you" bubble to jump to that terminal. Drag the cat to move it.
import Cocoa
import SwiftUI

// Top-level code isn't main-actor isolated here, but AppKit and the model need it.
MainActor.assumeIsolated {
    if CommandLine.arguments.contains("--test") { selfTest(); exit(0) }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)  // no dock icon
    // Fresh log, readable only by this user: it holds prompts and shell commands.
    try? FileManager.default.createDirectory(atPath: (eventsPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(atPath: eventsPath, contents: nil, attributes: [.posixPermissions: 0o600])

    let model = Model()
    let screen = NSScreen.main!.visibleFrame
    var origin = P(screen.maxX - 450, screen.minY + 6)
    if let s = defaults.string(forKey: "origin"), NSScreen.screens.contains(where: { $0.frame.contains(NSPointFromString(s)) }) {
        origin = NSPointFromString(s)  // where you left it, if that monitor is still here
    }
    // Non-activating panel: clicking the cat never steals focus from what you're doing.
    let panel = NSPanel(contentRect: NSRect(origin: origin, size: CGSize(width: 440, height: 320)),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.setFrame(panel.constrainFrameRect(panel.frame, to: NSScreen.screens.first { $0.frame.contains(origin) }), display: false)  // keep the whole panel on screen
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    panel.contentView = Host(rootView: Root(m: model))
    model.window = panel
    panel.orderFrontRegardless()

    Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in MainActor.assumeIsolated { model.tick() } }
    app.run()
}
