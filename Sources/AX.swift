import AppKit
import ApplicationServices

/// Accessibility access to other apps' windows — the only supported way left to move them.
enum AX {
    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias RemoteTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private static let getWindow: GetWindowFn? = SL.symbol("_AXUIElementGetWindow")
    private static let createWithRemoteToken: RemoteTokenFn? = SL.symbol("_AXUIElementCreateWithRemoteToken")

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        guard let getWindow, getWindow(element, &wid) == .success, wid != 0 else { return nil }
        return wid
    }

    /// Looks the window up in the app's Accessibility window list.
    static func window(pid: pid_t, wid: CGWindowID) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { windowID(of: $0) == wid }
    }

    /// Finds a window the list doesn't report (typically one on a hidden desktop) by probing
    /// the app's element IDs directly — the technique AltTab uses.
    static func windowByBruteForce(pid: pid_t, wid: CGWindowID) -> AXUIElement? {
        guard let createWithRemoteToken else { return nil }
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
        let deadline = Date().addingTimeInterval(2)
        for id in UInt64(0)..<1000 {
            if Date() > deadline { break }
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: id) { Data($0) })
            if let element = createWithRemoteToken(token as CFData)?.takeRetainedValue(), windowID(of: element) == wid {
                return element
            }
        }
        return nil
    }

    static func setFrame(_ window: AXUIElement, pid: pid_t, _ frame: CGRect) {
        // Apps with AXEnhancedUserInterface on (Chrome, Electron) animate or drop AX moves.
        let app = AXUIElementCreateApplication(pid)
        let enhanced = bool(app, "AXEnhancedUserInterface") == true
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        var origin = frame.origin, size = frame.size
        if let position = AXValueCreate(.cgPoint, &origin), let dimensions = AXValueCreate(.cgSize, &size) {
            // Position, size, position: the size a display allows depends on which display the window is on.
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        }
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
    }

    static func isMinimized(_ window: AXUIElement) -> Bool { bool(window, kAXMinimizedAttribute) == true }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }
}
