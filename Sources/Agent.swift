import AppKit

enum Command {
    static let notification = Notification.Name("com.mickecast.SpaceKeeper.command")
    static let bundleID = "com.mickecast.SpaceKeeper"
}

/// The background agent: saves the window layout every few seconds while nothing is changing,
/// and after a wake or a display reconnect puts windows back where that layout had them.
@MainActor
final class Agent: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = LayoutStore()
    private let restorer = Restorer()
    private var statusItem: NSStatusItem?
    private var timer: Timer?

    private var asleep = false
    private var disturbedAt = Date.distantPast
    private var wokeAt: Date?
    /// The display setup in use when the current disruption began.
    private var expectedKey: String?
    private var restoreCheckPending = false
    private var loggedWaiting = false
    private var lastSavedAt = Date.distantPast
    private var lastSaveLoggedAt = Date.distantPast
    private var lastRestoreSource: Snapshot?
    /// Set before a restore is queued, so no save slips in ahead of it.
    private var restoring = false
    private var paused = false
    private var knownDisplays: [CGDirectDisplayID: String] = [:]
    private var trusted = false

    /// How often the layout is saved while nothing is changing.
    private let saveInterval: TimeInterval = 10
    /// Quiet time after a display change before acting on it.
    private let settleDelay: TimeInterval = 3
    /// How long after waking to wait for displays to reconnect before taking the setup as final.
    private let wakeGrace: TimeInterval = 45
    /// A setup other than the one in use before a disruption is only restored automatically once
    /// it has been used this long — so a monitor that drops out for a minute isn't "restored" to.
    private let establishedAfter: TimeInterval = 600

    private var settled: Bool { Date().timeIntervalSince(disturbedAt) >= settleDelay }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        Log.write("SpaceKeeper \(version) started (pid \(getpid())) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        trusted = AX.isTrusted
        if !trusted {
            Log.write("Accessibility permission not granted yet — asking")
            AX.requestTrust()
        }
        if !WindowServer.separateSpaces {
            Log.write("warning: “Displays have separate Spaces” is off — windows can't be moved between desktops")
        }
        buildStatusItem()
        observeSystem()
        save(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: Events

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, String, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, "displays went to sleep", true),
            (NSWorkspace.willSleepNotification, "Mac is going to sleep", true),
            (NSWorkspace.screensDidWakeNotification, "displays woke", false),
            (NSWorkspace.didWakeNotification, "Mac woke", false),
        ]
        for (name, description, isSleep) in events {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { isSleep ? self?.sleeping(description) : self?.woke(description) }
            }
        }
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
        DistributedNotificationCenter.default().addObserver(forName: Command.notification, object: nil, queue: .main) { [weak self] note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.handle(command) }
        }
    }

    fileprivate func displayChanged(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags) {
        disturbedAt = Date()
        let kinds: [(CGDisplayChangeSummaryFlags, String)] = [
            (.addFlag, "connected"), (.removeFlag, "disconnected"), (.enabledFlag, "enabled"), (.disabledFlag, "disabled"),
            (.setModeFlag, "changed resolution"), (.setMainFlag, "became main"), (.mirrorFlag, "mirrored"), (.unMirrorFlag, "unmirrored"),
        ]
        let changes = kinds.filter { flags.contains($0.0) }.map(\.1)
        // Arrangement-only changes don't displace windows; begin-flags are followed by the real event.
        guard !flags.contains(.beginConfigurationFlag), !changes.isEmpty else { return }
        knownDisplays.merge(WindowServer.activeDisplayNames()) { _, new in new }
        Log.write("display \(knownDisplays[display] ?? WindowServer.describe(display)) \(changes.joined(separator: ", "))")
        beginDisruption()
    }

    private func beginDisruption() {
        if !restoreCheckPending { expectedKey = store.latest?.key }
        restoreCheckPending = true
        loggedWaiting = false
    }

    private func sleeping(_ what: String) {
        if !asleep {
            if !restoreCheckPending {
                if settled && WindowServer.sessionActive { save(force: false) }
                expectedKey = store.latest?.key
            }
            let taken = store.latest.map { $0.taken.formatted(date: .omitted, time: .standard) } ?? "never"
            Log.write("\(what) — holding the layout saved at \(taken): \(store.latest?.summary ?? "none")")
        }
        asleep = true
    }

    private func woke(_ what: String) {
        Log.write(what)
        asleep = false
        wokeAt = Date()
        disturbedAt = Date()
        beginDisruption()
    }

    private func tick() {
        if !trusted && AX.isTrusted {
            trusted = true
            Log.write("Accessibility permission granted")
        }
        guard !asleep, !restoring, settled, WindowServer.sessionActive, CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { return }
        if restoreCheckPending {
            checkDisplacedWindows()
        } else if Date().timeIntervalSince(lastSavedAt) >= saveInterval {
            save(force: false)
        }
    }

    private func checkDisplacedWindows() {
        let displays = WindowServer.displays()
        let key = WindowServer.configKey(displays)
        let names = displays.map(\.name).joined(separator: ", ")
        if let wokeAt, let expectedKey, key != expectedKey, Date().timeIntervalSince(wokeAt) < wakeGrace {
            if !loggedWaiting {
                loggedWaiting = true
                Log.write("waiting for displays to reconnect — currently \(names)")
            }
            return
        }
        restoreCheckPending = false
        wokeAt = nil
        guard let layout = store.layout(for: key) else {
            Log.write("displays settled (\(names)) — no saved layout for this setup yet")
            return
        }
        if key != expectedKey && (layout.observed ?? 0) < establishedAfter {
            Log.write("displays settled (\(names)) — this setup was only used briefly before, leaving windows as they are")
        } else if paused {
            Log.write("displays settled — automatic restore is paused")
        } else if !trusted {
            Log.write("displays settled — can't restore without Accessibility permission")
        } else {
            lastRestoreSource = layout
            restore(layout, reason: "displays settled", followUp: true)
        }
    }

    // MARK: Actions

    private func save(force: Bool) {
        let snapshot = WindowServer.snapshot()
        lastSavedAt = Date()
        knownDisplays.merge(WindowServer.activeDisplayNames()) { _, new in new }
        guard !snapshot.displays.isEmpty else { return }
        let changed = store.record(snapshot)
        if force || (changed && Date().timeIntervalSince(lastSaveLoggedAt) > 300) {
            lastSaveLoggedAt = Date()
            Log.write("saved layout: \(snapshot.summary)")
        }
    }

    private func restore(_ layout: Snapshot, reason: String, followUp: Bool = false) {
        guard !restoring else { return }
        restoring = true
        Task {
            _ = await restorer.restore(layout, reason: reason)
            if followUp {
                // macOS can re-home windows from a monitor's recreated first desktop a few seconds late.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                _ = await restorer.restore(layout, reason: "follow-up check", primary: false)
            }
            restoring = false
            disturbedAt = Date()  // let things settle before the next save
            lastSavedAt = .distantPast
        }
    }

    private func restorePrevious() {
        guard trusted else {
            Log.write("can't restore without Accessibility permission")
            return
        }
        let key = WindowServer.configKey(WindowServer.displays())
        guard let layout = lastRestoreSource?.key == key ? lastRestoreSource : store.layout(for: key) else {
            Log.write("no saved layout for this display setup")
            return
        }
        restore(layout, reason: "requested")
    }

    private func handle(_ command: String) {
        Log.write("command: \(command)")
        switch command {
        case "save": save(force: true)
        case "restore": restorePrevious()
        case "selftest": Task { await SelfTest.run(restorer: restorer) }
        default: Log.write("unknown command “\(command)”")
        }
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "SpaceKeeper")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: statusLine, action: nil, keyEquivalent: ""))
        if !trusted { addItem(to: menu, "Grant Accessibility Access…", #selector(openAccessibilitySettings)) }
        menu.addItem(.separator())
        addItem(to: menu, "Restore Previous Layout", #selector(restoreFromMenu))
        addItem(to: menu, "Save Layout Now", #selector(saveFromMenu))
        addItem(to: menu, "Pause Automatic Restore", #selector(togglePause)).state = paused ? .on : .off
        menu.addItem(.separator())
        addItem(to: menu, "Open Log", #selector(openLog))
        addItem(to: menu, "Quit SpaceKeeper", #selector(quit))
    }

    @discardableResult
    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private var statusLine: String {
        if restoring { return "Putting windows back…" }
        if !trusted { return "Needs Accessibility access" }
        if restoreCheckPending { return "Waiting for displays to settle…" }
        guard let latest = store.latest else { return "No layout saved yet" }
        let seconds = Int(Date().timeIntervalSince(latest.taken))
        let ago = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m"
        return "Saved \(ago) ago · \(latest.windows.count) windows on \(latest.displays.count) displays" + (paused ? " · paused" : "")
    }

    @objc private func restoreFromMenu() { restorePrevious() }
    @objc private func saveFromMenu() { save(force: true) }
    @objc private func openLog() { NSWorkspace.shared.open(Log.url) }
    @objc private func quit() { Log.write("quit from the menu"); NSApp.terminate(nil) }

    @objc private func togglePause() {
        paused.toggle()
        Log.write(paused ? "automatic restore paused" : "automatic restore resumed")
    }

    @objc private func openAccessibilitySettings() {
        AX.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

private func displayReconfigured(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let agent = Unmanaged<Agent>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { MainActor.assumeIsolated { agent.displayChanged(display, flags) } }
}
