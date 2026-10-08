import ApplicationServices
import CoreGraphics
import Foundation

/// Private WindowServer (SkyLight) calls, resolved at runtime so a symbol Apple removes
/// turns into a logged failure instead of a crash at launch.
enum SL {
    private static let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    static func symbol<T>(_ name: String, as type: T.Type = T.self) -> T? {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let pointer = skylight.flatMap({ dlsym($0, name) }) ?? dlsym(rtldDefault, name) else {
            Log.write("private symbol \(name) is missing on this macOS")
            return nil
        }
        return unsafeBitCast(pointer, to: type)
    }

    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CurrentSpaceFn = @convention(c) (Int32, CFString) -> UInt64
    private typealias MoveWindowsFn = @convention(c) (Int32, CFArray, UInt64) -> Void

    private static let mainConnection: MainConnectionFn? = symbol("SLSMainConnectionID")
    private static let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn? = symbol("SLSCopyManagedDisplaySpaces")
    private static let copySpacesForWindows: CopySpacesForWindowsFn? = symbol("SLSCopySpacesForWindows")
    private static let managedDisplayCurrentSpace: CurrentSpaceFn? = symbol("SLSManagedDisplayGetCurrentSpace")
    private static let moveWindowsToManagedSpace: MoveWindowsFn? = symbol("SLSMoveWindowsToManagedSpace")

    static let connection: Int32 = mainConnection?() ?? 0

    static func managedDisplaySpaces() -> [[String: Any]] {
        (copyManagedDisplaySpaces?(connection)?.takeRetainedValue() as? [[String: Any]]) ?? []
    }

    /// Desktops a window is on; more than one means it is set to appear on all desktops.
    static func spaces(forWindow wid: CGWindowID) -> [UInt64] {
        let ids = copySpacesForWindows?(connection, 0x7, [NSNumber(value: wid)] as CFArray)?.takeRetainedValue() as? [NSNumber]
        return ids?.map(\.uint64Value) ?? []
    }

    static func currentSpace(display uuid: String) -> UInt64 {
        managedDisplayCurrentSpace?(connection, uuid as CFString) ?? 0
    }

    /// Since macOS 14.5 this only works on windows this process owns — enough to carry our own
    /// anchor window to a desktop, not to move another app's window.
    static func moveOwnWindows(_ wids: [CGWindowID], toSpace sid: UInt64) {
        moveWindowsToManagedSpace?(connection, wids.map { NSNumber(value: $0) } as CFArray, sid)
    }

    private typealias SetFrontProcessFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostEventRecordFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private static let setFrontProcess: SetFrontProcessFn? = symbol("_SLPSSetFrontProcessWithOptions")
    private static let postEventRecord: PostEventRecordFn? = symbol("SLPSPostEventRecordTo")
    private static let getProcessForPID: GetProcessForPIDFn? = symbol("GetProcessForPID")

    /// Brings a process to the front with the given window key, as a click would. Unlike
    /// NSApp.activate, macOS honours this from a background agent; focusing a window on a
    /// hidden desktop makes its display switch to that desktop. (Same route as AltTab and yabai.)
    @discardableResult
    static func focus(pid: pid_t, wid: CGWindowID) -> Bool {
        var psn = ProcessSerialNumber()
        guard let getProcessForPID, let setFrontProcess, let postEventRecord, getProcessForPID(pid, &psn) == noErr else { return false }
        let userGenerated: UInt32 = 0x200
        guard setFrontProcess(&psn, wid, userGenerated) == .success else { return false }
        for phase: UInt8 in [0x01, 0x02] {  // synthesized "make key window" event records
            var record = [UInt8](repeating: 0, count: 0xf8)
            record[0x04] = 0xf8
            record[0x08] = phase
            record[0x3a] = 0x10
            withUnsafeBytes(of: wid) { record.replaceSubrange(0x3c..<0x40, with: $0) }
            for i in 0x20..<0x30 { record[i] = 0xff }
            _ = postEventRecord(&psn, &record)
        }
        return true
    }
}
