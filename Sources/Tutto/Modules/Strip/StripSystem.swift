//
//  StripSystem.swift
//  Tutto (scrolling strip)
//
//  The strip's contact with macOS: displays, Accessibility reads and writes, and one
//  observer per app that reports window changes as they happen (no polling).
//

import AppKit
import ApplicationServices
import TuttoKit

/// A display, in Accessibility coordinates (top-left origin of the main display, y down).
struct StripDisplay: Equatable {
    let id: CGDirectDisplayID
    let uuid: String
    let name: String
    let frame: CGRect
    /// Below the menu bar and beside the Dock.
    let visible: CGRect

    /// Left to right.
    static func all() -> [StripDisplay] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.compactMap { screen -> StripDisplay? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "\(id)"
            return StripDisplay(id: id, uuid: uuid, name: screen.localizedName,
                                frame: WindowLayout.flip(screen.frame, primaryHeight: primaryHeight),
                                visible: WindowLayout.flip(screen.visibleFrame, primaryHeight: primaryHeight))
        }
        .sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Cocoa (bottom-left origin) rect for an Accessibility rect.
    static func cocoa(_ rect: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Synchronous Accessibility calls. Each is one round trip to the app (usually well under a
/// millisecond; capped so a hung app can't stall Tutto).
enum StripAX {
    static let timeout: Float = 0.3

    static func app(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    static func windows(of pid: pid_t) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app(pid), kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        let list = value as? [AXUIElement] ?? []
        list.forEach { AXUIElementSetMessagingTimeout($0, timeout) }
        return list
    }

    static func focusedWindow(of pid: pid_t) -> AXUIElement? {
        element(app(pid), kAXFocusedWindowAttribute)
    }

    static func windowID(_ element: AXUIElement) -> CGWindowID? { WindowElements.windowID(of: element) }

    static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement  // swiftlint:disable:this force_cast
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? Bool) == true
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)  // swiftlint:disable:this force_cast
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)  // swiftlint:disable:this force_cast
        return CGRect(origin: position, size: size)
    }

    static func facts(_ element: AXUIElement, bundleID: String?) -> StripWindowFacts {
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable)
        return StripWindowFacts(role: string(element, kAXRoleAttribute), subrole: string(element, kAXSubroleAttribute),
                                bundleID: bundleID, size: frame(element)?.size ?? .zero, canResize: settable.boolValue,
                                isFullScreen: bool(element, "AXFullScreen"), isMinimized: bool(element, kAXMinimizedAttribute))
    }

    static func isFullScreen(_ element: AXUIElement) -> Bool { bool(element, "AXFullScreen") }
    static func isMinimized(_ element: AXUIElement) -> Bool { bool(element, kAXMinimizedAttribute) }
    static func title(_ element: AXUIElement) -> String { string(element, kAXTitleAttribute) ?? "" }

    /// How a frame is sent. A window keeps its size unless asked; growing it moves it first
    /// (macOS fits a new size into the room below and beside a window's current corner),
    /// shrinking resizes it first, and a final frame is sent size, position, size so an app that
    /// clamped the first size to its old spot gets it right.
    enum FrameOrder: Sendable {
        case positionOnly, growing, shrinking, settle
    }

    static func setFrame(_ frame: CGRect, of element: AXUIElement, order: FrameOrder) {
        var origin = frame.origin
        var size = frame.size
        guard let originValue = AXValueCreate(.cgPoint, &origin), let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        func position() { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, originValue) }
        func resize() { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue) }
        switch order {
        case .positionOnly:
            position()
        case .growing:
            position()
            resize()
        case .shrinking:
            resize()
            position()
        case .settle:
            resize()
            position()
            resize()
        }
    }

    static func setFrame(_ frame: CGRect, of element: AXUIElement, size setSize: Bool) {
        setFrame(frame, of: element, order: setSize ? .settle : .positionOnly)
    }

    /// Every window id on screen right now (a background native tab isn't).
    static func onScreenWindowIDs() -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return Set(list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
    }

    /// Every window id that exists, on screen or not. Ids only: about ten times quicker than
    /// asking for every window's details, and it doesn't wait while a busy window server writes
    /// them all out (that took 60 ms at times, on every strip key).
    static func existingWindowIDs() -> Set<CGWindowID> {
        if let windowListCreate, let list = windowListCreate([.optionAll, .excludeDesktopElements], kCGNullWindowID)?.takeRetainedValue() {
            let count = CFArrayGetCount(list)
            var ids = Set<CGWindowID>(minimumCapacity: count)
            for index in 0..<count { ids.insert(CGWindowID(UInt(bitPattern: CFArrayGetValueAtIndex(list, index)))) }
            return ids
        }
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return Set(list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
    }

    // CGWindowListCreate (a list of bare window numbers) isn't offered to Swift.
    private typealias WindowListCreate = @convention(c) (CGWindowListOption, CGWindowID) -> Unmanaged<CFArray>?
    private static let windowListCreate = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreate")
        .map { unsafeBitCast($0, to: WindowListCreate.self) }

    /// Front-to-back order of on-screen windows.
    static func zOrder() -> [CGWindowID: Int] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var order: [CGWindowID: Int] = [:]
        for (index, info) in list.enumerated() {
            if let id = info[kCGWindowNumber as String] as? CGWindowID { order[id] = index }
        }
        return order
    }
}

/// Watches one app's windows through an AXObserver on the main run loop. Created when the
/// strip first meets the app; released when the app quits or the strip stops.
@MainActor
final class StripAppObserver {
    enum Event {
        case created(AXUIElement)
        case focusChanged(AXUIElement?)
        case destroyed(AXUIElement)
        case moved(AXUIElement)
        case resized(AXUIElement)
        case minimized(AXUIElement)
        case deminimized(AXUIElement)
        case titleChanged(AXUIElement)
    }

    let pid: pid_t
    private var observer: AXObserver?
    private let application: AXUIElement
    private var watched: [CGWindowID: AXUIElement] = [:]
    private let handler: (pid_t, Event) -> Void

    private static let appNotifications = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification]
    private static let windowNotifications = [kAXUIElementDestroyedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
                                              kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification]

    init?(pid: pid_t, handler: @escaping (pid_t, Event) -> Void) {
        self.pid = pid
        self.handler = handler
        application = StripAX.app(pid)
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let observer = Unmanaged<StripAppObserver>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { observer.deliver(name, element) }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return nil }
        observer = created
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var registered = 0
        for name in Self.appNotifications where AXObserverAddNotification(created, application, name as CFString, refcon) == .success {
            registered += 1
        }
        // An app that answers nothing (still launching, or not an app with windows) is tried again later.
        guard registered > 0 else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
    }

    func watch(_ element: AXUIElement, as window: CGWindowID) {
        guard let observer else { return }
        if let current = watched[window] {
            // Some apps hand out a new element for a window (after minimizing): watch that one.
            guard !CFEqual(current, element) else { return }
            unwatch(window)
        }
        watched[window] = element
        // A window element handed over by a notice waits as long as macOS allows on a hung app.
        AXUIElementSetMessagingTimeout(element, StripAX.timeout)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.windowNotifications {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
    }

    func unwatch(_ window: CGWindowID) {
        guard let observer, let element = watched.removeValue(forKey: window) else { return }
        for name in Self.windowNotifications {
            AXObserverRemoveNotification(observer, element, name as CFString)
        }
    }

    func isWatching(_ window: CGWindowID) -> Bool { watched[window] != nil }

    /// The window an element belongs to, even once it's destroyed and can't be asked.
    func window(for element: AXUIElement) -> CGWindowID? {
        watchedWindow(for: element)?.id ?? StripAX.windowID(element)
    }

    /// The watched window an element is, found without asking its app (busy redrawing while the
    /// strip moves it), with the element it's watched by.
    func watchedWindow(for element: AXUIElement) -> (id: CGWindowID, element: AXUIElement)? {
        watched.first { CFEqual($0.value, element) }.map { ($0.key, $0.value) }
    }

    func invalidate() {
        guard let observer else { return }
        for id in Array(watched.keys) { unwatch(id) }
        for name in Self.appNotifications {
            AXObserverRemoveNotification(observer, application, name as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
    }

    private func deliver(_ name: String, _ element: AXUIElement) {
        switch name {
        case kAXWindowCreatedNotification: handler(pid, .created(element))
        case kAXFocusedWindowChangedNotification: handler(pid, .focusChanged(element))
        case kAXUIElementDestroyedNotification: handler(pid, .destroyed(element))
        case kAXWindowMovedNotification: handler(pid, .moved(element))
        case kAXWindowResizedNotification: handler(pid, .resized(element))
        case kAXWindowMiniaturizedNotification: handler(pid, .minimized(element))
        case kAXWindowDeminiaturizedNotification: handler(pid, .deminimized(element))
        case kAXTitleChangedNotification: handler(pid, .titleChanged(element))
        default: break
        }
    }
}

/// Moves windows off the main thread: one serial queue per app, so a slow app never holds
/// up the others, and only the newest frame for a window is ever sent (frames that a busy
/// app hasn't taken yet are replaced, not queued up).
final class StripMover: @unchecked Sendable {
    private struct Request {
        var element: AXUIElement
        var frame: CGRect
        var order: StripAX.FrameOrder
    }

    private let lock = NSLock()
    private var pending: [CGWindowID: Request] = [:]
    private var queues: [pid_t: DispatchQueue] = [:]
    /// Apps whose "enhanced user interface" is switched off while they're being moved: with it
    /// on (assistive apps turn it on), an app animates every move itself, slowly.
    private var enhancedOff: [pid_t: DispatchWorkItem] = [:]

    func move(_ window: CGWindowID, pid: pid_t, element: AXUIElement, to frame: CGRect, order: StripAX.FrameOrder) {
        // Tutto's own windows answer Accessibility in-process, on the calling thread; AppKit
        // windows can't be moved from these background queues.
        guard pid != getpid() else { return }
        lock.lock()
        let waiting = pending[window] != nil
        var request = Request(element: element, frame: frame, order: order)
        // A frame that replaces one not sent yet still carries its size change.
        if let older = pending[window], older.order != .positionOnly, order == .positionOnly { request.order = .settle }
        pending[window] = request
        let queue = queue(for: pid)
        lock.unlock()
        guard !waiting else { return }
        queue.async { [weak self] in self?.send(window, pid: pid) }
    }

    /// ⌃⌥ held: the app in front is about to have its windows moved. Its enhanced interface goes
    /// off now, so the burst of work that is for the app is over before the first frame.
    func expectMoves(of pid: pid_t) {
        guard pid != getpid() else { return }
        lock.lock()
        let queue = queue(for: pid)
        lock.unlock()
        queue.async { [weak self] in self?.holdEnhancedInterfaceOff(pid) }
    }

    /// Runs Accessibility work for an app in order with its moves.
    func run(pid: pid_t, _ work: @escaping @Sendable () -> Void) {
        lock.lock()
        let queue = queue(for: pid)
        lock.unlock()
        queue.async(execute: work)
    }

    /// The window's actual frame after the app has had `delay` to settle, on the main thread.
    func readFrame(of element: AXUIElement, pid: pid_t, after delay: TimeInterval, then: @escaping @MainActor (CGRect?) -> Void) {
        nonisolated(unsafe) let element = element
        lock.lock()
        let queue = queue(for: pid)
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay) {
            let frame = StripAX.frame(element)
            DispatchQueue.main.async { MainActor.assumeIsolated { then(frame) } }
        }
    }

    func forget(pid: pid_t) {
        lock.lock()
        queues[pid] = nil
        enhancedOff.removeValue(forKey: pid)?.cancel()
        lock.unlock()
    }

    private func queue(for pid: pid_t) -> DispatchQueue {
        if let queue = queues[pid] { return queue }
        let queue = DispatchQueue(label: "ca.bryanyao.Tutto.strip.\(pid)", qos: .userInteractive)
        queues[pid] = queue
        return queue
    }

    private func send(_ window: CGWindowID, pid: pid_t) {
        lock.lock()
        let request = pending.removeValue(forKey: window)
        lock.unlock()
        guard let request else { return }
        holdEnhancedInterfaceOff(pid)
        StripAX.setFrame(request.frame, of: request.element, order: request.order)
    }

    /// Called on the app's queue before each move; switches the app's enhanced interface back
    /// on once it has been still for a few seconds. (Switching it on makes the app rebuild its
    /// whole accessibility tree, a burst of work it shouldn't be doing as the next key comes.)
    private func holdEnhancedInterfaceOff(_ pid: pid_t) {
        lock.lock()
        let restore = enhancedOff[pid]
        lock.unlock()
        if let restore {
            restore.cancel()
        } else {
            let app = StripAX.app(pid)
            guard StripAX.bool(app, "AXEnhancedUserInterface") else { return }
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }
        let work = DispatchWorkItem { [weak self] in
            AXUIElementSetAttributeValue(StripAX.app(pid), "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            self?.lock.withLock { _ = self?.enhancedOff.removeValue(forKey: pid) }
        }
        lock.lock()
        enhancedOff[pid] = work
        let queue = queue(for: pid)
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 4, execute: work)
    }
}

/// Calls back once per display refresh while something is moving; paused (no wakeups at all)
/// the rest of the time.
@MainActor
final class StripDisplayLink: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private let tick: (Double) -> Void

    init(tick: @escaping (Double) -> Void) {
        self.tick = tick
        super.init()
    }

    var isRunning: Bool { link?.isPaused == false }

    func start() {
        if link == nil {
            let screen = NSScreen.main ?? NSScreen.screens.first
            link = screen?.displayLink(target: self, selector: #selector(step(_:)))
            link?.add(to: .main, forMode: .common)
        }
        guard let link, link.isPaused || last == 0 else { return }
        last = 0
        link.isPaused = false
    }

    func stop() {
        link?.isPaused = true
        last = 0
    }

    func invalidate() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = last == 0 ? link.duration : min(now - last, 1.0 / 20)
        last = now
        tick(max(dt, 1.0 / 240))
    }
}
