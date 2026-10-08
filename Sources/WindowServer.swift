import AppKit

struct DisplayState: Codable, Equatable {
    var uuid: String
    /// Vendor, model, serial and size — stable across reconnects even if macOS issues a new UUID.
    var fingerprint: String
    var name: String
    /// Global coordinates, top-left origin (same space as CGWindow bounds and AX positions).
    var frame: CGRect
    /// Desktops in Mission Control order; full-screen app spaces are left out.
    var spaces: [UInt64]
    var currentSpace: UInt64
}

struct WindowState: Codable, Equatable {
    var wid: CGWindowID
    var pid: pid_t
    var app: String
    var space: UInt64
    var display: String
    var frame: CGRect
}

struct Snapshot: Codable {
    var taken: Date
    var key: String
    var displays: [DisplayState]
    var windows: [WindowState]
    /// Total time this display setup has been seen in use, across sessions.
    var observed: TimeInterval?

    func display(_ uuid: String) -> DisplayState? { displays.first { $0.uuid == uuid } }

    /// Where every window sits — compared to skip rewriting the store when nothing moved.
    var placement: [CGWindowID: String] {
        Dictionary(windows.map { w in
            (w.wid, "\(w.space)@\(Int(w.frame.minX)),\(Int(w.frame.minY)),\(Int(w.frame.width)),\(Int(w.frame.height))")
        }, uniquingKeysWith: { first, _ in first })
    }

    var summary: String {
        let perDisplay = displays.map { d in
            "\(d.name): \(windows.filter { $0.display == d.uuid }.count) on \(d.spaces.count) desktops"
        }
        return "\(windows.count) windows — " + perDisplay.joined(separator: "; ")
    }
}

/// Reads displays, desktops and window placement from the WindowServer.
@MainActor
enum WindowServer {
    static func displayUUID(_ did: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue() else { return "display-\(did)" }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func uuid(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return displayUUID(CGDirectDisplayID(number.uint32Value))
    }

    static func screen(for uuid: String) -> NSScreen? {
        NSScreen.screens.first { self.uuid(of: $0) == uuid }
    }

    struct SpaceLayout {
        var desktops: [UInt64]
        var all: Set<UInt64>
        var current: UInt64
    }

    static func spaceLayouts() -> [String: SpaceLayout] {
        var layouts: [String: SpaceLayout] = [:]
        for entry in SL.managedDisplaySpaces() {
            guard var identifier = entry["Display Identifier"] as? String else { continue }
            if identifier == "Main" { identifier = displayUUID(CGMainDisplayID()) }
            var layout = SpaceLayout(desktops: [], all: [], current: 0)
            for space in entry["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = (space["id64"] as? NSNumber ?? space["ManagedSpaceID"] as? NSNumber)?.uint64Value else { continue }
                layout.all.insert(id)
                if (space["type"] as? NSNumber)?.intValue ?? 0 == 0 { layout.desktops.append(id) }
            }
            layout.current = ((entry["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value ?? 0
            layouts[identifier] = layout
        }
        return layouts
    }

    static func displays() -> [DisplayState] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        let layouts = spaceLayouts()
        var result: [DisplayState] = []
        for did in ids.prefix(Int(count)) where CGDisplayMirrorsDisplay(did) == kCGNullDirectDisplay {
            let uuid = displayUUID(did)
            let bounds = CGDisplayBounds(did)
            let layout = layouts[uuid]
            result.append(DisplayState(
                uuid: uuid,
                fingerprint: "\(CGDisplayVendorNumber(did))-\(CGDisplayModelNumber(did))-\(CGDisplaySerialNumber(did))@\(Int(bounds.width))x\(Int(bounds.height))",
                name: screen(for: uuid)?.localizedName ?? "Display \(did)",
                frame: bounds,
                spaces: layout?.desktops ?? [],
                currentSpace: layout?.current ?? 0))
        }
        // Two identical monitors without serial numbers would share a fingerprint.
        let shared = Set(Dictionary(grouping: result, by: \.fingerprint).filter { $0.value.count > 1 }.keys)
        for i in result.indices where shared.contains(result[i].fingerprint) { result[i].fingerprint += "#" + result[i].uuid }
        return result.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
    }

    static func configKey(_ displays: [DisplayState]) -> String {
        displays.map(\.fingerprint).sorted().joined(separator: " | ")
    }

    /// Ordinary app windows that live on exactly one desktop. Windows on every desktop,
    /// in full-screen spaces, minimised or belonging to menu-bar helpers are left alone.
    static func windows(on displays: [DisplayState]) -> [WindowState] {
        var owner: [UInt64: String] = [:]
        for display in displays { for space in display.spaces { owner[space] = display.uuid } }
        let regularApps = Dictionary(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { ($0.processIdentifier, $0.localizedName ?? "?") }, uniquingKeysWith: { first, _ in first })
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var windows: [WindowState] = []
        for info in list {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let wid = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != getpid(),
                  let app = regularApps[pid],
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width >= 120, frame.height >= 100 else { continue }
            let spaces = SL.spaces(forWindow: wid)
            guard spaces.count == 1, let display = owner[spaces[0]] else { continue }
            windows.append(WindowState(wid: wid, pid: pid, app: app, space: spaces[0], display: display, frame: frame))
        }
        return windows
    }

    /// Current placement of one window, whatever kind of app owns it.
    static func windowState(_ wid: CGWindowID, displays: [DisplayState]) -> WindowState? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]])?.first,
              let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
        let spaces = SL.spaces(forWindow: wid)
        guard spaces.count == 1, let display = displays.first(where: { $0.spaces.contains(spaces[0]) }) else { return nil }
        return WindowState(wid: wid, pid: pid, app: info[kCGWindowOwnerName as String] as? String ?? "?",
                           space: spaces[0], display: display.uuid, frame: frame)
    }

    /// The desktop a window is on and the display that desktop belongs to.
    static func locate(_ wid: CGWindowID) -> (space: UInt64, display: String)? {
        let spaces = SL.spaces(forWindow: wid)
        guard spaces.count == 1 else { return nil }
        for (display, layout) in spaceLayouts() where layout.all.contains(spaces[0]) { return (spaces[0], display) }
        return nil
    }

    static func snapshot() -> Snapshot {
        let displays = displays()
        return Snapshot(taken: Date(), key: configKey(displays), displays: displays, windows: windows(on: displays), observed: nil)
    }

    static var separateSpaces: Bool {
        !(UserDefaults(suiteName: "com.apple.spaces")?.bool(forKey: "spans-displays") ?? false)
    }

    /// False while the screen is locked or another user has the console.
    static var sessionActive: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        let locked = (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
        let onConsole = (session[kCGSessionOnConsoleKey as String] as? Bool) ?? true
        return onConsole && !locked
    }

    static func describe(_ did: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue() else { return "display \(did)" }
        let id = CFUUIDCreateString(nil, uuid) as String
        return "\(screen(for: id)?.localizedName ?? "display \(did)") [\(id.prefix(8))]"
    }

    /// Names of the connected displays, kept by the agent so a disconnect can still be named.
    /// Displays AppKit can't name yet (mid-reconnect) are left out so a good cached name survives.
    static func activeDisplayNames() -> [CGDirectDisplayID: String] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [:] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [:] }
        var names: [CGDirectDisplayID: String] = [:]
        for did in ids.prefix(Int(count)) {
            let uuid = displayUUID(did)
            guard let name = screen(for: uuid)?.localizedName, !name.isEmpty else { continue }
            names[did] = "\(name) [\(uuid.prefix(8))]"
        }
        return names
    }

    /// "C34J79x desktop 3", for the log.
    static func desktopName(_ space: UInt64, in displays: [DisplayState]) -> String {
        guard let display = displays.first(where: { $0.spaces.contains(space) }), let index = display.spaces.firstIndex(of: space) else {
            return "space \(space)"
        }
        return "\(display.name) desktop \(index + 1)"
    }

    /// Why a window isn't on a single desktop of a connected display, for the log.
    static func whereabouts(_ wid: CGWindowID, displays: [DisplayState]) -> String {
        guard (CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]])?.isEmpty == false else { return "closed" }
        let spaces = SL.spaces(forWindow: wid)
        if spaces.isEmpty { return "on no desktop — minimised, hidden or in transit" }
        if spaces.count > 1 { return "on \(spaces.count) desktops" }
        if displays.contains(where: { $0.spaces.contains(spaces[0]) }) { return desktopName(spaces[0], in: displays) }
        return "on space \(spaces[0]), which isn't a desktop of any connected display"
    }
}
