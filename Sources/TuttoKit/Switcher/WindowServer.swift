//
//  WindowServer.swift
//  Tutto (window switcher)
//
//  Every window of every app, on every Space, straight from the window server.
//
//  Accessibility only lists an app's windows on the current Space, and an app whose
//  windows all sit in other full-screen Spaces reports none at all. The window server
//  knows them all: CGWindowList gives ids, owners, titles and z-order, and the window
//  server's per-window flags (tags, attributes, parent) tell a real document window from
//  the dozens of helper surfaces every app keeps around (menu bar ghosts, full-screen
//  toolbar strips, off-screen buffers).
//
//  The flag meanings below were measured on this Mac (macOS 26.5), not guessed:
//    real window, normal or full screen   tags bit 0 set, attributes bit 1 (shown)
//    minimized                            + tags bit 60, no longer shown
//    app hidden (⌘H)                      + tags bit 39, no longer shown
//    full-screen toolbar strips           tags bit 0 clear
//    menu bar ghosts, off-screen buffers  never shown (attributes bit 1 clear)
//
//  The window server calls are private. They're looked up at runtime, so a future macOS
//  that drops one degrades to "fewer details", never to a crash.
//

import AppKit
import ApplicationServices
import CoreGraphics

/// One window as the window server reports it.
public struct ServerWindow: Equatable, Sendable {
    public let id: CGWindowID
    public let pid: pid_t
    /// The window's title. Empty without Screen Recording permission.
    public let title: String
    /// Global coordinates, top-left origin (CoreGraphics).
    public let frame: CGRect
    public let alpha: Double
    public let layer: Int
    /// Position in the window server's front-to-back order (0 = frontmost).
    public let zIndex: Int
    public var tags: UInt64
    public var attributes: UInt64
    public var parent: CGWindowID

    public init(id: CGWindowID, pid: pid_t, title: String, frame: CGRect, alpha: Double = 1, layer: Int = 0, zIndex: Int = 0,
                tags: UInt64 = 0, attributes: UInt64 = 0, parent: CGWindowID = 0) {
        self.id = id
        self.pid = pid
        self.title = title
        self.frame = frame
        self.alpha = alpha
        self.layer = layer
        self.zIndex = zIndex
        self.tags = tags
        self.attributes = attributes
        self.parent = parent
    }

    public var isMinimized: Bool { WindowFlags.isMinimized(tags) }
    public var isAppHidden: Bool { WindowFlags.isAppHidden(tags) }
}

/// What the window server's per-window flags mean.
public enum WindowFlags {
    /// A document window (as opposed to utility surfaces).
    public static func isDocument(_ tags: UInt64) -> Bool {
        tags & 0x1 != 0 || (tags & 0x2 != 0 && tags & 0x8000_0000 != 0)
    }

    /// Currently ordered in, i.e. part of its Space's window stack.
    public static func isShown(_ attributes: UInt64) -> Bool { attributes & 0x2 != 0 }

    public static func isMinimized(_ tags: UInt64) -> Bool { tags & (1 << 60) != 0 }

    public static func isAppHidden(_ tags: UInt64) -> Bool { tags & (1 << 39) != 0 }
}

/// A Space as the window server describes it.
public struct SpaceInfo: Equatable, Sendable {
    public let id: UInt64
    public let isFullScreen: Bool
    /// "Desktop 2" numbering among the display's normal desktops (1-based); 0 for full screen.
    public let desktopNumber: Int
    public let isCurrent: Bool
}

public enum WindowServer {
    // MARK: Private symbols

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias Query = @convention(c) (Int32, CFArray, Int32) -> Unmanaged<CFTypeRef>?
    private typealias CopyWindows = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    private typealias Advance = @convention(c) (CFTypeRef) -> Bool
    private typealias Get32 = @convention(c) (CFTypeRef) -> UInt32
    private typealias Get64 = @convention(c) (CFTypeRef) -> UInt64
    private typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyManagedSpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias Capture = @convention(c) (Int32, UnsafeMutablePointer<UInt32>, Int32, UInt32) -> Unmanaged<CFArray>?

    private static let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        dlsym(sky, name).map { unsafeBitCast($0, to: type) }
    }

    private static let mainConnection = symbol("SLSMainConnectionID", MainConnection.self)
    private static let query = symbol("SLSWindowQueryWindows", Query.self)
    private static let copyWindows = symbol("SLSWindowQueryResultCopyWindows", CopyWindows.self)
    private static let advance = symbol("SLSWindowIteratorAdvance", Advance.self)
    private static let windowID = symbol("SLSWindowIteratorGetWindowID", Get32.self)
    private static let parentID = symbol("SLSWindowIteratorGetParentID", Get32.self)
    private static let tags = symbol("SLSWindowIteratorGetTags", Get64.self)
    private static let attributes = symbol("SLSWindowIteratorGetAttributes", Get64.self)
    private static let copySpaces = symbol("SLSCopySpacesForWindows", CopySpaces.self)
    private static let copyManagedSpaces = symbol("SLSCopyManagedDisplaySpaces", CopyManagedSpaces.self)
    private static let capture = symbol("SLSHWCaptureWindowList", Capture.self)

    static var connection: Int32 { mainConnection?() ?? 0 }

    /// True when the calls that tell real windows from helper surfaces are available.
    public static var canClassify: Bool { query != nil && copyWindows != nil && advance != nil && tags != nil }

    // MARK: Listing

    /// Every layer-0 window owned by `pids`, front to back, with the window server's flags;
    /// `onScreenOnly`: just the ones on screen (a far shorter list to ask about).
    public static func windows(of pids: Set<pid_t>, onScreenOnly: Bool = false) -> [ServerWindow] {
        let which: CGWindowListOption = onScreenOnly ? .optionOnScreenOnly : .optionAll
        guard let list = CGWindowListCopyWindowInfo([which, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result: [ServerWindow] = []
        result.reserveCapacity(64)
        for (index, info) in list.enumerated() {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? [String: Double] else { continue }
            let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            // Anything smaller than this is never a window someone switches to (and skipping
            // it here keeps the flag query small).
            guard frame.width >= 50, frame.height >= 50 else { continue }
            result.append(ServerWindow(id: id, pid: pid, title: info[kCGWindowName as String] as? String ?? "", frame: frame,
                                       alpha: info[kCGWindowAlpha as String] as? Double ?? 1, layer: 0, zIndex: index))
        }
        attachFlags(&result)
        return result
    }

    /// Fills in tags, attributes and parent with one window-server query for all windows.
    static func attachFlags(_ windows: inout [ServerWindow]) {
        guard !windows.isEmpty, let query, let copyWindows, let advance, let windowID, let tags, let attributes else { return }
        let ids = windows.map { NSNumber(value: $0.id) } as CFArray
        guard let result = query(connection, ids, Int32(windows.count))?.takeRetainedValue(),
              let iterator = copyWindows(result)?.takeRetainedValue() else { return }
        var flags: [CGWindowID: (UInt64, UInt64, CGWindowID)] = [:]
        while advance(iterator) {
            flags[windowID(iterator)] = (tags(iterator), attributes(iterator), parentID?(iterator) ?? 0)
        }
        for index in windows.indices {
            guard let (t, a, p) = flags[windows[index].id] else { continue }
            windows[index].tags = t
            windows[index].attributes = a
            windows[index].parent = p
        }
    }

    // MARK: Spaces

    /// Every Space on every display, keyed by id.
    public static func spaces() -> [UInt64: SpaceInfo] {
        guard let copyManagedSpaces, let displays = copyManagedSpaces(connection)?.takeRetainedValue() as? [[String: Any]] else {
            return [:]
        }
        var result: [UInt64: SpaceInfo] = [:]
        for display in displays {
            let current = ((display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value
            var desktop = 0
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = (space["ManagedSpaceID"] as? NSNumber)?.uint64Value else { continue }
                let fullScreen = (space["type"] as? NSNumber)?.intValue == 4
                if !fullScreen { desktop += 1 }
                result[id] = SpaceInfo(id: id, isFullScreen: fullScreen, desktopNumber: fullScreen ? 0 : desktop, isCurrent: id == current)
            }
        }
        return result
    }

    /// The Space showing on each display, keyed by display UUID ("Main" for every display
    /// when Displays have separate Spaces is off).
    public static func currentSpaces() -> [String: SpaceInfo] {
        guard let copyManagedSpaces, let displays = copyManagedSpaces(connection)?.takeRetainedValue() as? [[String: Any]] else {
            return [:]
        }
        var result: [String: SpaceInfo] = [:]
        for display in displays {
            guard let identifier = display["Display Identifier"] as? String,
                  let current = display["Current Space"] as? [String: Any],
                  let id = (current["ManagedSpaceID"] as? NSNumber)?.uint64Value else { continue }
            let fullScreen = (current["type"] as? NSNumber)?.intValue == 4
            result[identifier] = SpaceInfo(id: id, isFullScreen: fullScreen, desktopNumber: 0, isCurrent: true)
        }
        return result
    }

    /// Every Space in the order Mission Control shows them, display by display.
    public static func spaceOrder() -> [UInt64] {
        guard let copyManagedSpaces, let displays = copyManagedSpaces(connection)?.takeRetainedValue() as? [[String: Any]] else {
            return []
        }
        return displays.flatMap { display in
            (display["Spaces"] as? [[String: Any]] ?? []).compactMap { ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value }
        }
    }

    /// The Space a window is on (the first, if it's briefly on two during a transition).
    public static func space(of window: CGWindowID) -> UInt64? {
        guard let copySpaces,
              let ids = copySpaces(connection, 0x7, [NSNumber(value: window)] as CFArray)?.takeRetainedValue() as? [NSNumber] else {
            return nil
        }
        return ids.first?.uint64Value
    }

    // MARK: Capture

    /// A picture of one window, wherever it is (other Spaces and full screen included;
    /// minimized windows give their last picture). Blocks for 5–60 ms; call off the main thread.
    public static func capture(_ window: CGWindowID) -> CGImage? {
        guard let capture else { return nil }
        var id = window
        // Ignore the screen's clip shape (1 << 11), nominal resolution (1 << 9): points, not pixels.
        let images = capture(connection, &id, 1, (1 << 11) | (1 << 9))?.takeRetainedValue() as? [CGImage]
        return images?.first
    }

    // MARK: Front window

    /// The topmost normal window on screen right now.
    public static func frontWindow() -> (id: CGWindowID, pid: pid_t)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list where (info[kCGWindowLayer as String] as? Int) == 0 {
            let bounds = info[kCGWindowBounds as String] as? [String: Double] ?? [:]
            guard (bounds["Width"] ?? 0) >= 100, (bounds["Height"] ?? 0) >= 100,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            return (id, pid)
        }
        return nil
    }

    /// Names this login, during which window numbers stay unique (they start over after logging
    /// out): the window server's session ID, or the boot time with the audit session if that's missing.
    public static let loginSession: String = {
        let info = CGSessionCopyCurrentDictionary() as? [String: Any]
        if let id = info?["CGSSessionUniqueSessionUUID"] as? String, !id.isEmpty { return id }
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return "" }
        return "\(boot.tv_sec)-\(info?["kCGSSessionAuditIDKey"] as? Int ?? 0)"
    }()

    /// The normal windows on screen right now, front to back.
    public static func onScreenWindows() -> [CGWindowID] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            (info[kCGWindowLayer as String] as? Int) == 0 ? info[kCGWindowNumber as String] as? CGWindowID : nil
        }
    }

    /// The topmost on-screen window of one app.
    public static func frontWindow(of pid: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list where (info[kCGWindowOwnerPID as String] as? pid_t) == pid && (info[kCGWindowLayer as String] as? Int) == 0 {
            let bounds = info[kCGWindowBounds as String] as? [String: Double] ?? [:]
            guard (bounds["Width"] ?? 0) >= 100, (bounds["Height"] ?? 0) >= 100,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            return info[kCGWindowNumber as String] as? CGWindowID
        }
        return nil
    }

    /// Whether a window still exists.
    public static func exists(_ window: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]] else { return false }
        return !list.isEmpty
    }
}

// MARK: - Accessibility for any window

/// Accessibility elements for windows, including ones on other Spaces.
public enum WindowElements {
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias Create = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private static let hi = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_NOW)
    private static let getWindow = dlsym(hi, "_AXUIElementGetWindow").map { unsafeBitCast($0, to: GetWindow.self) }
    private static let createRemote = dlsym(hi, "_AXUIElementCreateWithRemoteToken").map { unsafeBitCast($0, to: Create.self) }

    /// The window server id behind an Accessibility window element.
    public static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var id: CGWindowID = 0
        return getWindow(element, &id) == .success && id != 0 ? id : nil
    }

    // Elements found earlier, by window. An element stays valid while its window exists, even
    // after the window moves to another Space, and raising it is what takes macOS there.
    // macOS only creates an element for a window once something asks for it, so a window on
    // another Space that nobody has touched since its app started can't be found at all;
    // remembering every window you've been in covers almost everything.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [CGWindowID: AXUIElement] = [:]

    private static func cached(_ window: CGWindowID) -> AXUIElement? {
        guard let element = cacheLock.withLock({ cache[window] }) else { return nil }
        if windowID(of: element) == window { return element }
        cacheLock.withLock { cache[window] = nil }
        return nil
    }

    private static func remember(_ element: AXUIElement, as window: CGWindowID) {
        cacheLock.withLock {
            cache[window] = element
            if cache.count > 256 { cache.removeAll() }
        }
    }

    /// Remembers a window element handed over by a focus notification.
    public static func remember(_ element: AXUIElement) {
        if let id = windowID(of: element) { remember(element, as: id) }
    }

    /// Forgets elements of windows that no longer exist.
    public static func prune(keeping live: Set<CGWindowID>) {
        cacheLock.withLock { cache = cache.filter { live.contains($0.key) } }
    }

    /// Remembers the element of the app's focused window (it's on the current Space, so this
    /// is cheap). Called when an app comes to the front.
    public static func rememberFocusedWindow(of pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
        let element = value as! AXUIElement  // swiftlint:disable:this force_cast
        if let id = windowID(of: element) { remember(element, as: id) }
    }

    /// The element for `window` of app `pid`: remembered, from the app's window list when the
    /// window is on this Space, or rebuilt from a remote token. Can take up to `budget`
    /// seconds for an app that's slow to answer; call off the main thread.
    public static func element(for window: CGWindowID, pid: pid_t, budget: TimeInterval = 0.25) -> AXUIElement? {
        if let element = cached(window) { return element }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(max(budget, 0.1)))
        for attribute in [kAXWindowsAttribute, kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, attribute as CFString, &value) == .success else { continue }
            let candidates: [AXUIElement]
            if let list = value as? [AXUIElement] {
                candidates = list
            } else if let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                candidates = [value as! AXUIElement]  // swiftlint:disable:this force_cast
            } else {
                continue
            }
            for candidate in candidates { if let id = windowID(of: candidate) { remember(candidate, as: id) } }
            if let match = candidates.first(where: { windowID(of: $0) == window }) { return match }
        }
        let remote = remoteElement(for: window, pid: pid, budget: budget)
        if let remote { remember(remote, as: window) }
        return remote
    }

    /// Chooses the window from its app's Window menu, by exact title: the app then brings
    /// that window forward itself and macOS follows it to its Space. The way in for a window
    /// that has no element yet. True if a matching item was pressed.
    public static func chooseFromWindowMenu(title: String, pid: pid_t) -> Bool {
        guard !title.isEmpty else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        func children(_ element: AXUIElement) -> [AXUIElement] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
            return value as? [AXUIElement] ?? []
        }
        func name(of element: AXUIElement) -> String {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
            return value as? String ?? ""
        }
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success, let bar,
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return false }
        // The Window menu is usually second to last (before Help); look there first, then everywhere.
        var menus = children(bar as! AXUIElement)  // swiftlint:disable:this force_cast
        if menus.count >= 2 { menus.insert(menus.remove(at: menus.count - 2), at: 0) }
        for menu in menus.prefix(12) {
            for submenu in children(menu) {
                if let item = children(submenu).first(where: { name(of: $0) == title }) {
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    /// macOS lets a client rebuild an element from a "remote token": the pid, a fixed
    /// marker and an element number. Windows on other Spaces are found by trying numbers.
    static func remoteElement(for window: CGWindowID, pid: pid_t, budget: TimeInterval) -> AXUIElement? {
        guard let createRemote else { return nil }
        let deadline = Date().addingTimeInterval(budget)
        var token = Data(count: 20)
        token.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: pid, toByteOffset: 0, as: Int32.self)
            raw.storeBytes(of: Int32(0), toByteOffset: 4, as: Int32.self)
            raw.storeBytes(of: Int32(0x636f_636f), toByteOffset: 8, as: Int32.self)
        }
        for number in UInt64(0)..<0x8000 {
            if number % 64 == 0, Date() > deadline { return nil }
            token.withUnsafeMutableBytes { $0.storeBytes(of: number, toByteOffset: 12, as: UInt64.self) }
            guard let element = createRemote(token as CFData)?.takeRetainedValue(), windowID(of: element) == window else { continue }
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if (role as? String) == kAXWindowRole { return element }
        }
        return nil
    }
}

// MARK: - Focus

/// Brings one exact window to the front, switching Spaces if it's elsewhere.
public enum WindowFocus {
    private typealias SetFront = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> Int32
    private typealias PostRecord = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>) -> Int32
    private typealias ProcessForPID = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
    private static let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static let services = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW)
    private static let setFront = dlsym(sky, "_SLPSSetFrontProcessWithOptions").map { unsafeBitCast($0, to: SetFront.self) }
    private static let postRecord = dlsym(sky, "SLPSPostEventRecordTo").map { unsafeBitCast($0, to: PostRecord.self) }
    private static let processForPID = dlsym(services, "GetProcessForPID").map { unsafeBitCast($0, to: ProcessForPID.self) }

    /// Makes `window` the key window of its app and the frontmost window on screen.
    /// `element` (when known) is raised too, which is what moves macOS to the window's Space.
    /// Blocks briefly on Accessibility; call off the main thread.
    @discardableResult
    public static func focus(window: CGWindowID, pid: pid_t, element: AXUIElement?) -> Bool {
        // One of Tutto's own windows: Accessibility would run AppKit on this (background)
        // thread, which aborts. Bring it forward on the main thread instead.
        if pid == getpid() {
            DispatchQueue.main.async {
                NSApp.windows.first { $0.windowNumber == Int(window) }?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            return true
        }
        if let element {
            var minimized: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized) == .success, (minimized as? Bool) == true {
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
        }
        var fronted = false
        if let setFront, let postRecord, let processForPID {
            var psn = [UInt32](repeating: 0, count: 2)
            if psn.withUnsafeMutableBytes({ processForPID(pid, $0.baseAddress!) }) == 0 {
                // 0x200: user generated, like a click in the Dock.
                fronted = psn.withUnsafeMutableBytes { setFront($0.baseAddress!, window, 0x200) } == 0
                // "Make key window": a synthetic click addressed to the window at a point far
                // outside it, so nothing inside the window is clicked. The mouse-up matters: after
                // a mouse-down alone the window server waits for the button to come up, and a
                // full-screen app's menu bar won't slide down until a real click ends it.
                var bytes = [UInt8](repeating: 0, count: 0x100)
                bytes[0x04] = 0xF8
                bytes[0x3A] = 0x10
                withUnsafeBytes(of: CGPoint(x: 300_000, y: 300_000)) { for (i, b) in $0.enumerated() { bytes[0x20 + i] = b } }
                withUnsafeBytes(of: window.littleEndian) { for (i, b) in $0.enumerated() { bytes[0x3C + i] = b } }
                for phase: UInt8 in [0x01, 0x02] {  // down, then up
                    bytes[0x08] = phase
                    _ = psn.withUnsafeMutableBytes { p in bytes.withUnsafeMutableBufferPointer { postRecord(p.baseAddress!, $0.baseAddress!) } }
                }
            }
        }
        if let element {
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        if !fronted {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
        return fronted || element != nil
    }
}
