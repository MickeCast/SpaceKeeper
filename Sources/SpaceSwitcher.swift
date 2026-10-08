import AppKit

/// Brings a given desktop into view on one display. macOS no longer lets a third-party app
/// move other apps' windows between desktops, but it can still carry its *own* window to a
/// desktop and activate it — which makes macOS switch that display to the desktop. A window
/// moved onto a display then lands on whichever desktop is showing there.
///
/// The anchor window doubles as a small status panel so the desktop flipping is explained.
@MainActor
final class SpaceSwitcher {
    private final class AnchorWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private let label = NSTextField(labelWithString: "")
    private lazy var window: AnchorWindow = makeWindow()

    func show(_ space: UInt64, on display: String, message: String) async -> Bool {
        if SL.currentSpace(display: display) == space { return true }
        guard let screen = WindowServer.screen(for: display) else { return false }
        label.stringValue = message
        // Floating windows don't pull their desktop into view, so the anchor stays at normal level.
        window.level = .normal
        // Re-show it so focusing it is a fresh change, and only carry it over once it's on
        // screen — a window that hasn't landed yet ignores the move.
        window.orderOut(nil)
        place(on: screen)
        window.orderFrontRegardless()
        let wid = CGWindowID(window.windowNumber)
        _ = await waitUntil(timeout: 1) { !SL.spaces(forWindow: wid).isEmpty }
        var carried = false
        for _ in 0..<10 {
            SL.moveOwnWindows([wid], toSpace: space)
            carried = await waitUntil(timeout: 0.1) { SL.spaces(forWindow: wid) == [space] }
            if carried { break }
        }
        let focused = SL.focus(pid: getpid(), wid: wid)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if await waitUntil(timeout: 3, { SL.currentSpace(display: display) == space }) {
            try? await Task.sleep(nanoseconds: 250_000_000)  // let the slide animation finish
            return true
        }
        Log.write("  couldn't bring desktop \(space) into view on \(display.prefix(8)): it shows \(SL.currentSpace(display: display)),"
            + " anchor \(carried ? "carried" : "not carried") to \(SL.spaces(forWindow: wid)), focus call \(focused ? "ok" : "failed"),"
            + " active \(NSApp.isActive), front app \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        return false
    }

    /// Shows a closing message on the main display's current desktop, then hides the panel.
    func finish(message: String) async {
        guard let screen = NSScreen.screens.first else {
            window.orderOut(nil)
            return
        }
        label.stringValue = message
        window.orderOut(nil)
        window.level = .floating  // above the windows of the app that just got focus back
        place(on: screen)
        window.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        window.orderOut(nil)
    }

    private func place(on screen: NSScreen) {
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 24))
    }

    private func makeWindow() -> AnchorWindow {
        let frame = NSRect(x: 0, y: 0, width: 360, height: 38)
        let window = AnchorWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.ignoresCycle]
        let background = NSVisualEffectView(frame: frame)
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        label.frame = NSRect(x: 12, y: 10, width: frame.width - 24, height: 18)
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        background.addSubview(label)
        window.contentView = background
        return window
    }
}

/// Polls until `condition` holds or `timeout` passes, without blocking the main run loop.
@MainActor
func waitUntil(timeout: TimeInterval = 1.5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 40_000_000)
    }
    return condition()
}
