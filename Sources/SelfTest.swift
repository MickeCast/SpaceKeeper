import AppKit

/// Sends a throwaway window through every restore path and logs the outcome. None of the
/// user's windows are touched, but desktops visibly flip for a few seconds.
@MainActor
enum SelfTest {
    static func run(restorer: Restorer) async {
        guard AX.isTrusted else { Log.write("self-test: needs Accessibility permission"); return }
        guard !restorer.isRunning else { Log.write("self-test: a restore is already running"); return }
        guard let executable = Bundle.main.executableURL else { return }
        Log.write("self-test: starting")
        let helper = Process()
        helper.executableURL = executable
        helper.arguments = ["testwindow", "120"]
        let pipe = Pipe()
        helper.standardOutput = pipe
        do {
            try helper.run()
        } catch {
            Log.write("self-test: couldn't open the test window: \(error)")
            return
        }
        defer { helper.terminate() }
        let output = await Task.detached { String(data: pipe.fileHandleForReading.availableData, encoding: .utf8) ?? "" }.value
        guard let wid = CGWindowID(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            Log.write("self-test: the test window didn't report its ID (\(output))")
            return
        }
        try? await Task.sleep(nanoseconds: 600_000_000)

        let displays = WindowServer.displays()
        guard let start = WindowServer.windowState(wid, displays: displays),
              let home = displays.first(where: { $0.uuid == start.display }) else {
            Log.write("self-test: can't see the test window")
            return
        }
        guard let away = displays.filter({ $0.uuid != home.uuid }).max(by: { $0.spaces.count < $1.spaces.count }),
              let hidden = away.spaces.last(where: { $0 != away.currentSpace }),
              let other = away.spaces.first(where: { $0 != away.currentSpace && $0 != hidden }) else {
            Log.write("self-test: needs a second display with at least three desktops")
            return
        }
        let size = start.frame.size
        let middle = CGRect(x: away.frame.midX - size.width / 2, y: away.frame.midY - size.height / 2, width: size.width, height: size.height)
        let cases: [(String, DisplayState, UInt64, CGRect)] = [
            ("onto a hidden desktop of another display", away, hidden, middle),
            ("onto another desktop of the same display", away, other, middle.offsetBy(dx: 80, dy: 60)),
            ("back home from a hidden desktop", home, start.space, start.frame),
        ]
        var passed = 0
        for (index, (name, display, space, frame)) in cases.enumerated() {
            if index == 2, let location = WindowServer.locate(wid), SL.currentSpace(display: location.display) != location.space {
                let listed = AX.window(pid: start.pid, wid: wid) != nil
                let probed = AX.windowByBruteForce(pid: start.pid, wid: wid) != nil
                Log.write("self-test: on a hidden desktop the window is \(listed ? "" : "not ")in the AX window list and \(probed ? "" : "not ")found by probing")
            }
            var window = start
            window.display = display.uuid
            window.space = space
            window.frame = frame
            let plan = Snapshot(taken: Date(), key: WindowServer.configKey(displays), displays: displays, windows: [window], observed: nil)
            let began = Date()
            _ = await restorer.restore(plan, reason: "self-test \(name)", primary: false)
            let now = SL.spaces(forWindow: wid)
            let ok = now == [space]
            if ok { passed += 1 }
            Log.write(String(format: "self-test %@ %@ (%.1fs)", ok ? "PASS" : "FAIL", name, Date().timeIntervalSince(began))
                + (ok ? "" : " — window is on \(now), expected \(space)"))
        }
        Log.write("self-test: \(passed)/\(cases.count) passed")
    }
}

/// The throwaway window the self-test moves around, run as a separate process so it is
/// "another app's window" exactly like the ones a real restore moves.
enum TestWindow {
    @MainActor
    static func run(seconds: Double) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "SpaceKeeper self-test — closes by itself"
        window.center()
        window.orderFrontRegardless()
        print(window.windowNumber)
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
        app.run()
        exit(0)
    }
}
