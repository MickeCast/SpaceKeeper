import AppKit

/// Puts windows back on the display, desktop and frame recorded in a snapshot.
@MainActor
final class Restorer {
    struct Report {
        var moved = 0, failed = 0, skipped = 0, inPlace = 0
        var text: String { "\(moved) moved, \(failed) failed, \(skipped) skipped, \(inPlace) already in place" }
    }

    private struct Move {
        let wid: CGWindowID
        let pid: pid_t
        let app: String
        let display: DisplayState  // live state of the display it belongs on
        let space: UInt64
        let frame: CGRect
        var from: WindowState
        let origin: String
        var name: String { "\(app) #\(wid)" }
        var destination: String { "\(display.name) desktop \((display.spaces.firstIndex(of: space) ?? 0) + 1)" }
    }

    private let switcher = SpaceSwitcher()
    private(set) var isRunning = false

    /// Where the last real restore found each window, for working out what macOS did.
    static let recordURL = LayoutStore.url.deletingLastPathComponent().appendingPathComponent("last-restore.json")

    /// A primary pass keeps a record of what it found and reports the windows it leaves alone;
    /// the follow-up check and the self-test don't.
    func restore(_ saved: Snapshot, reason: String, primary: Bool = true) async -> Report {
        var report = Report()
        guard !isRunning else { return report }
        isRunning = true
        defer { isRunning = false }

        let displays = WindowServer.displays()
        var liveDisplay: [String: DisplayState] = [:]  // saved display UUID → that display now
        for display in saved.displays {
            if let match = displays.first(where: { $0.fingerprint == display.fingerprint }) { liveDisplay[display.uuid] = match }
        }
        var liveSpace: [UInt64: UInt64] = [:]  // saved desktop → that desktop now
        for display in saved.displays {
            guard let match = liveDisplay[display.uuid] else { continue }
            liveSpace.merge(Self.mapDesktops(saved: display.spaces, live: match.spaces)) { first, _ in first }
        }

        var moves: [Move] = []
        var unhandled: [String] = []
        var found: [String: String] = [:]
        for window in saved.windows {
            found["\(window.app) #\(window.wid)"] = WindowServer.whereabouts(window.wid, displays: displays)
            // Closed, minimised, full screen or now on every desktop: nothing to do.
            guard let now = WindowServer.windowState(window.wid, displays: displays), now.pid == window.pid else {
                unhandled.append("\(window.app) #\(window.wid) (\(WindowServer.whereabouts(window.wid, displays: displays)))")
                continue
            }
            guard let oldDisplay = saved.display(window.display), let display = liveDisplay[window.display],
                  let space = liveSpace[window.space] ?? display.spaces.last else {
                report.skipped += 1
                continue
            }
            let frame = Self.fit(window.frame.offsetBy(dx: display.frame.minX - oldDisplay.frame.minX,
                                                       dy: display.frame.minY - oldDisplay.frame.minY), in: display.frame)
            if now.space == space && Self.near(now.frame, frame) {
                report.inPlace += 1
                continue
            }
            if liveSpace[window.space] == nil {
                Log.write("  \(window.app) #\(window.wid): its desktop on \(display.name) is gone — using the last one")
            }
            moves.append(Move(wid: window.wid, pid: window.pid, app: window.app, display: display, space: space, frame: frame,
                              from: now, origin: WindowServer.desktopName(now.space, in: displays)))
        }
        if primary {
            Self.keepRecord(reason: reason, saved: saved, displays: displays, found: found)
            if !unhandled.isEmpty { Log.write("  left alone: " + unhandled.joined(separator: "; ")) }
        }

        guard !moves.isEmpty else {
            Log.write("restore (\(reason)): nothing to do — \(report.inPlace) windows already in place")
            return report
        }
        Log.write("restore (\(reason)): \(moves.count) window(s) to put back, \(report.inPlace) already in place")
        let frontmost = NSWorkspace.shared.frontmostApplication
        var failed = Set<CGWindowID>()

        // A window only changes desktops by changing displays, so one that belongs on a different
        // desktop of the display it's already on is parked on another display first.
        for i in moves.indices where moves[i].from.space != moves[i].space && moves[i].from.display == moves[i].display.uuid {
            let move = moves[i]
            let others = displays.filter { $0.uuid != move.display.uuid }
            let main = WindowServer.displayUUID(CGMainDisplayID())
            guard let park = others.first(where: { $0.uuid == main }) ?? others.first else {
                Log.write("  ✗ \(move.name) → \(move.destination): changing desktops needs a second display")
                failed.insert(move.wid)
                continue
            }
            guard let element = await reach(move) else {
                Log.write("  ✗ \(move.name): Accessibility can't reach it")
                failed.insert(move.wid)
                continue
            }
            let size = move.from.frame.size
            AX.setFrame(element, pid: move.pid, Self.fit(CGRect(x: park.frame.midX - size.width / 2, y: park.frame.midY - size.height / 2,
                                                                width: size.width, height: size.height), in: park.frame))
            _ = await waitUntil { WindowServer.locate(move.wid)?.display == park.uuid }
            if let location = WindowServer.locate(move.wid) {
                moves[i].from.space = location.space
                moves[i].from.display = location.display
            }
        }

        // Then one desktop at a time: bring it into view and move its windows onto that display.
        var order: [String] = []
        var groups: [String: [Move]] = [:]
        for move in moves where !failed.contains(move.wid) {
            let key = "\(move.display.uuid)#\(move.space)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(move)
        }
        for key in order {
            guard let group = groups[key], let first = group.first else { continue }
            guard await switcher.show(first.space, on: first.display.uuid, message: "SpaceKeeper · putting windows back on \(first.destination)") else {
                for move in group { Log.write("  ✗ \(move.name) → \(move.destination): couldn't switch to that desktop") }
                failed.formUnion(group.map(\.wid))
                continue
            }
            for move in group {
                guard let element = await reach(move) else {
                    Log.write("  ✗ \(move.name): Accessibility can't reach it")
                    failed.insert(move.wid)
                    continue
                }
                if AX.isMinimized(element) {
                    report.skipped += 1
                    continue
                }
                AX.setFrame(element, pid: move.pid, move.frame)
                if await waitUntil({ SL.spaces(forWindow: move.wid) == [move.space] }) {
                    report.moved += 1
                    Log.write(move.from.space == move.space
                        ? "  ✓ \(move.name): position restored on \(move.destination)"
                        : "  ✓ \(move.name) → \(move.destination) (was on \(move.origin))")
                } else {
                    failed.insert(move.wid)
                    Log.write("  ✗ \(move.name) → \(move.destination): ended up on desktop \(SL.spaces(forWindow: move.wid))")
                }
            }
        }
        report.failed = failed.count

        // Leave every display showing the desktop it showed before, and hand focus back.
        for display in saved.displays {
            guard let match = liveDisplay[display.uuid], let space = liveSpace[display.currentSpace] else { continue }
            _ = await switcher.show(space, on: match.uuid, message: "SpaceKeeper · restoring \(match.name)")
        }
        if let frontmost, frontmost.processIdentifier != getpid(), !frontmost.isTerminated {
            NSApp.yieldActivation(to: frontmost)
            frontmost.activate()
        }
        await switcher.finish(message: "SpaceKeeper put back \(report.moved) window\(report.moved == 1 ? "" : "s")")
        Log.write("restore (\(reason)) finished: \(report.text)")
        return report
    }

    private struct Record: Codable {
        var at: Date
        var reason: String
        var saved: Snapshot
        var displays: [DisplayState]
        var found: [String: String]
    }

    private static func keepRecord(reason: String, saved: Snapshot, displays: [DisplayState], found: [String: String]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let record = Record(at: Date(), reason: reason, saved: saved, displays: displays, found: found)
        try? encoder.encode(record).write(to: recordURL, options: .atomic)
    }

    /// The app's Accessibility window list only covers desktops that are on screen, so a window
    /// on a hidden desktop has its desktop brought into view before asking again.
    private func reach(_ move: Move) async -> AXUIElement? {
        if let element = AX.window(pid: move.pid, wid: move.wid) { return element }
        if let location = WindowServer.locate(move.wid), SL.currentSpace(display: location.display) != location.space {
            _ = await switcher.show(location.space, on: location.display, message: "SpaceKeeper · putting windows back")
            if let element = AX.window(pid: move.pid, wid: move.wid) { return element }
        }
        return AX.windowByBruteForce(pid: move.pid, wid: move.wid)
    }

    /// Pairs saved desktops with live ones: same ID first, then the leftovers in order — macOS
    /// sometimes recreates a display's first desktop under a new ID when it reconnects.
    static func mapDesktops(saved: [UInt64], live: [UInt64]) -> [UInt64: UInt64] {
        var map: [UInt64: UInt64] = [:]
        let liveSet = Set(live)
        for space in saved where liveSet.contains(space) { map[space] = space }
        var spare = live.filter { !saved.contains($0) }
        for space in saved where map[space] == nil && !spare.isEmpty { map[space] = spare.removeFirst() }
        return map
    }

    static func fit(_ frame: CGRect, in bounds: CGRect) -> CGRect {
        var fitted = frame
        fitted.size.width = min(fitted.width, bounds.width)
        fitted.size.height = min(fitted.height, bounds.height)
        fitted.origin.x = min(max(fitted.minX, bounds.minX), bounds.maxX - fitted.width)
        fitted.origin.y = min(max(fitted.minY, bounds.minY), bounds.maxY - fitted.height)
        return fitted
    }

    static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 8 && abs(a.minY - b.minY) <= 8 && abs(a.width - b.width) <= 8 && abs(a.height - b.height) <= 8
    }
}
