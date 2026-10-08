import AppKit

@MainActor
enum CLI {
    static func usage() {
        print("""
        usage: spacekeeper [command]
          (none)     run the background agent (launchd starts it at login)
          dump       print every display, its desktops and the windows on each
          status     show whether the agent is running, saved layouts and recent log lines
          save       ask the agent to save the current layout now
          restore    ask the agent to put windows back to the previous layout
          selftest   ask the agent to move a throwaway window around and log the result
                     (desktops flip for a few seconds; your windows aren't touched)
        """)
    }

    static func dump() {
        let snapshot = WindowServer.snapshot()
        for display in snapshot.displays {
            let f = display.frame
            print("\(display.name)  \(Int(f.width))x\(Int(f.height)) at \(Int(f.minX)),\(Int(f.minY))  [\(display.uuid)]")
            for (index, space) in display.spaces.enumerated() {
                let windows = snapshot.windows.filter { $0.space == space }.map { "\($0.app) #\($0.wid)" }
                print("  \(space == display.currentSpace ? "▸" : " ") desktop \(index + 1) [\(space)]  \(windows.joined(separator: ", "))")
            }
        }
        print("setup: \(snapshot.key)")
    }

    static func status() {
        let pids = agentPIDs()
        print(pids.isEmpty ? "agent: not running" : "agent: running (pid \(pids.map(String.init).joined(separator: ", ")))")
        for layout in LayoutStore().layouts.values.sorted(by: { $0.taken > $1.taken }) {
            print("layout saved \(layout.taken.formatted(date: .abbreviated, time: .standard)): \(layout.summary)")
        }
        if let log = try? String(contentsOf: Log.url, encoding: .utf8) {
            print("--- \(Log.url.path)")
            log.split(separator: "\n").suffix(25).forEach { print($0) }
        }
    }

    static func send(_ command: String) {
        guard !agentPIDs().isEmpty else {
            print("the SpaceKeeper agent isn't running")
            exit(1)
        }
        DistributedNotificationCenter.default().postNotificationName(Command.notification, object: command, userInfo: nil, deliverImmediately: true)
        print("sent “\(command)” to the agent — follow along with: tail -f \"\(Log.url.path)\"")
    }

    static func agentPIDs() -> [pid_t] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Command.bundleID)
            .map(\.processIdentifier)
            .filter { $0 != getpid() }
    }
}

// Top-level code runs on the main thread; say so, since AppKit and the agent are main-actor bound.
MainActor.assumeIsolated {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first {
    case nil:
        if !CLI.agentPIDs().isEmpty {
            Log.write("another SpaceKeeper agent is already running — exiting")
            exit(0)
        }
        let app = NSApplication.shared
        let agent = Agent()
        app.delegate = agent
        app.setActivationPolicy(.accessory)
        app.run()
    case "dump":
        CLI.dump()
    case "status":
        CLI.status()
    case "save", "restore", "selftest":
        CLI.send(arguments[0])
    case "testwindow":
        TestWindow.run(seconds: arguments.dropFirst().first.flatMap(Double.init) ?? 120)
    case "help", "-h", "--help":
        CLI.usage()
    default:
        CLI.usage()
        exit(2)
    }
}
