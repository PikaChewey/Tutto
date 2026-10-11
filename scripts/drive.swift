// Drives Tutto for live tests by posting real keyboard and mouse events.
//
//   swift scripts/drive.swift key cmd+shift+2          press a shortcut
//   swift scripts/drive.swift keyto Tutto ctrl+opt+cmd+j   deliver a key press to one app only
//   swift scripts/drive.swift type "left half"         type text
//   swift scripts/drive.swift drag 200 200 600 500     drag (global top-left points)
//   swift scripts/drive.swift click 400 300
//   swift scripts/drive.swift windows Tutto            list on-screen windows of an app
//   swift scripts/drive.swift frame                    frame of the frontmost window (AX)
//   swift scripts/drive.swift pasteboard               types and size on the clipboard
//
// Posting events needs Accessibility for the process that runs this script.
import AppKit
import Carbon.HIToolbox

let args = Array(CommandLine.arguments.dropFirst())
let source = CGEventSource(stateID: .hidSystemState)

let keyCodes: [String: Int] = [
    "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G,
    "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N,
    "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
    "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
    "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5,
    "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9, "`": kVK_ANSI_Grave, "grave": kVK_ANSI_Grave,
    "space": kVK_Space, "return": kVK_Return, "enter": kVK_Return, "esc": kVK_Escape, "escape": kVK_Escape, "tab": kVK_Tab,
    "delete": kVK_Delete, "down": kVK_DownArrow, "up": kVK_UpArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
    "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, "-": kVK_ANSI_Minus, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
]

func press(_ combo: String) {
    var flags: CGEventFlags = []
    var key = ""
    for part in combo.lowercased().split(separator: "+") {
        switch part {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "opt", "option", "alt": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        default: key = String(part)
        }
    }
    guard let code = keyCodes[key] else { fatalError("unknown key \(key)") }
    let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true)!
    let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false)!
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    usleep(20_000)
    up.post(tap: .cghidEventTap)
    usleep(30_000)
}

/// Posts a key press straight into one app's event queue, so it can never land in another app
/// (or in whatever the person at the Mac is typing into). Modifiers arrive as flagsChanged first, like a keyboard.
func press(_ combo: String, toApp name: String) {
    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) else { fatalError("\(name) isn't running") }
    let pid = app.processIdentifier
    let privateSource = CGEventSource(stateID: .privateState)
    var flags: CGEventFlags = []
    var key = ""
    var modifierKeys: [(CGEventFlags, Int)] = []
    for part in combo.lowercased().split(separator: "+") {
        switch part {
        case "cmd", "command": modifierKeys.append((.maskCommand, kVK_Command))
        case "shift": modifierKeys.append((.maskShift, kVK_Shift))
        case "opt", "option", "alt": modifierKeys.append((.maskAlternate, kVK_Option))
        case "ctrl", "control": modifierKeys.append((.maskControl, kVK_Control))
        default: key = String(part)
        }
    }
    func post(_ event: CGEvent) { event.postToPid(pid); usleep(25_000) }
    for (flag, code) in modifierKeys {
        flags.insert(flag)
        let event = CGEvent(keyboardEventSource: privateSource, virtualKey: CGKeyCode(code), keyDown: true)!
        event.type = .flagsChanged
        event.flags = flags
        post(event)
    }
    guard let code = keyCodes[key] else { fatalError("unknown key \(key)") }
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: privateSource, virtualKey: CGKeyCode(code), keyDown: down)!
        event.flags = flags
        post(event)
    }
    for (flag, code) in modifierKeys.reversed() {
        flags.remove(flag)
        let event = CGEvent(keyboardEventSource: privateSource, virtualKey: CGKeyCode(code), keyDown: false)!
        event.type = .flagsChanged
        event.flags = flags
        post(event)
    }
}

func type(_ text: String) {
    // Letters, digits and space go as real key codes (like a keyboard); anything else as Unicode.
    for character in text.lowercased() {
        let key = character == " " ? "space" : String(character)
        if keyCodes[key] != nil {
            press(key)
            continue
        }
        typeUnicode(String(character))
    }
}

func typeUnicode(_ text: String) {
    for scalar in text.unicodeScalars {
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)!
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)!
        var utf16 = Array(String(scalar).utf16)
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        usleep(15_000)
    }
}

func mouse(_ type: CGEventType, _ point: CGPoint) {
    CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!.post(tap: .cghidEventTap)
}

switch args.first {
case "key":
    press(args[1])
case "cmdtab":
    // A real ⌘-Tab: ⌘ goes down as its own key (the app switcher ignores a Tab that only carries the flag).
    func key(_ code: Int, _ down: Bool, _ flags: CGEventFlags) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)!
        if code == kVK_Command { event.type = .flagsChanged }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        usleep(60_000)
    }
    key(kVK_Command, true, .maskCommand)
    key(kVK_Tab, true, .maskCommand)
    key(kVK_Tab, false, .maskCommand)
    usleep(150_000)
    key(kVK_Command, false, [])
case "keyto":
    press(args[2], toApp: args[1])
case "type":
    type(args.dropFirst().joined(separator: " "))
case "move":
    mouse(.mouseMoved, CGPoint(x: Double(args[1])!, y: Double(args[2])!))
case "click":
    let point = CGPoint(x: Double(args[1])!, y: Double(args[2])!)
    mouse(.mouseMoved, point); usleep(50_000)
    mouse(.leftMouseDown, point); usleep(40_000)
    mouse(.leftMouseUp, point)
case "scroll":
    // Scroll wheel at a point: drive scroll x y lines (positive scrolls content up, like swiping up).
    let point = CGPoint(x: Double(args[1])!, y: Double(args[2])!)
    mouse(.mouseMoved, point); usleep(80_000)
    let lines = Int32(args[3])!
    for _ in 0..<abs(lines) {
        CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: lines > 0 ? -1 : 1, wheel2: 0, wheel3: 0)!
            .post(tap: .cghidEventTap)
        usleep(16_000)
    }
case "down":
    // Press and hold the left button at a point (pair with "dragto" and "up").
    let point = CGPoint(x: Double(args[1])!, y: Double(args[2])!)
    mouse(.mouseMoved, point); usleep(60_000)
    mouse(.leftMouseDown, point)
case "dragto":
    // Move with the button held, in small steps: drive dragto fromX fromY toX toY
    let a = CGPoint(x: Double(args[1])!, y: Double(args[2])!), b = CGPoint(x: Double(args[3])!, y: Double(args[4])!)
    for step in 1...15 {
        let t = Double(step) / 15
        mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        usleep(16_000)
    }
case "up":
    mouse(.leftMouseUp, CGPoint(x: Double(args[1])!, y: Double(args[2])!))
case "doubleclick":
    let point = CGPoint(x: Double(args[1])!, y: Double(args[2])!)
    mouse(.mouseMoved, point); usleep(80_000)
    for clickState in [1, 2] {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            event.post(tap: .cghidEventTap)
            usleep(40_000)
        }
        usleep(60_000)
    }
case "rightclick":
    let point = CGPoint(x: Double(args[1])!, y: Double(args[2])!)
    mouse(.mouseMoved, point); usleep(80_000)
    CGEvent(mouseEventSource: source, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)!.post(tap: .cghidEventTap)
    usleep(50_000)
    CGEvent(mouseEventSource: source, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)!.post(tap: .cghidEventTap)
case "drag":
    let a = CGPoint(x: Double(args[1])!, y: Double(args[2])!)
    let b = CGPoint(x: Double(args[3])!, y: Double(args[4])!)
    mouse(.mouseMoved, a); usleep(80_000)
    mouse(.leftMouseDown, a); usleep(60_000)
    for step in 1...20 {
        let t = Double(step) / 20
        mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        usleep(12_000)
    }
    mouse(.leftMouseUp, b)
case "windows":
    let name = args.count > 1 ? args[1] : ""
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for info in list where name.isEmpty || (info[kCGWindowOwnerName as String] as? String ?? "").contains(name) {
        let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
        print(info[kCGWindowOwnerName as String] ?? "", "layer", info[kCGWindowLayer as String] ?? "",
              "bounds", bounds["X"] ?? "", bounds["Y"] ?? "", bounds["Width"] ?? "", bounds["Height"] ?? "",
              "name", info[kCGWindowName as String] ?? "")
    }
case "frame":
    guard let app = NSWorkspace.shared.frontmostApplication else { break }
    let element = AXUIElementCreateApplication(app.processIdentifier)
    var window: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window)
    guard let window else { print(app.localizedName ?? "", "no window"); break }
    var position: CFTypeRef?, size: CFTypeRef?
    AXUIElementCopyAttributeValue(window as! AXUIElement, kAXPositionAttribute as CFString, &position)
    AXUIElementCopyAttributeValue(window as! AXUIElement, kAXSizeAttribute as CFString, &size)
    var p = CGPoint.zero, s = CGSize.zero
    AXValueGetValue(position as! AXValue, .cgPoint, &p)
    AXValueGetValue(size as! AXValue, .cgSize, &s)
    print(app.localizedName ?? "", "frame", Int(p.x), Int(p.y), Int(s.width), Int(s.height))
case "pasteboard":
    let pb = NSPasteboard.general
    for type in pb.types ?? [] {
        let data = pb.data(forType: type)
        print(type.rawValue, data?.count ?? 0)
    }
    if let png = pb.data(forType: .png), let rep = NSBitmapImageRep(data: png) {
        print("png pixels", rep.pixelsWide, "x", rep.pixelsHigh)
    }
    if let text = pb.string(forType: .string) { print("text:", text.prefix(200)) }
case "statusitem":
    // Presses an app's menu bar extra through Accessibility (works even when the notch hides it).
    let name = args[1]
    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) else { print("not running"); break }
    let element = AXUIElementCreateApplication(app.processIdentifier)
    var bar: CFTypeRef?
    AXUIElementCopyAttributeValue(element, "AXExtrasMenuBar" as CFString, &bar)
    guard let bar else { print("no extras menu bar"); break }
    var children: CFTypeRef?
    AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children)
    let items = children as? [AXUIElement] ?? []
    print("items", items.count)
    for item in items {
        var position: CFTypeRef?
        AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &position)
        var p = CGPoint.zero
        if let position { AXValueGetValue(position as! AXValue, .cgPoint, &p) }
        print("item at", Int(p.x), Int(p.y), "press:", AXUIElementPerformAction(item, kAXPressAction as CFString).rawValue)
    }
case "taps":
    // Event taps installed by a process (Trackpad Corner's lives only while the module is on).
    var count: UInt32 = 0
    CGGetEventTapList(0, nil, &count)
    var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
    CGGetEventTapList(count, &taps, &count)
    let pid = Int32(args[1])!
    let mine = taps.filter { $0.tappingProcess == pid }
    print("taps for \(pid):", mine.count, mine.map { "enabled=\($0.enabled) mask=\(String($0.eventsOfInterest, radix: 16))" })
case "focus":
    // Which app and element have keyboard focus system-wide (to type only into the right place).
    let system = AXUIElementCreateSystemWide()
    var element: CFTypeRef?
    AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &element)
    guard let element else { print("no focus"); break }
    var pid: pid_t = 0
    AXUIElementGetPid(element as! AXUIElement, &pid)
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(element as! AXUIElement, kAXRoleAttribute as CFString, &role)
    print(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?", pid, role as? String ?? "?")
case "axpress":
    // Presses the first button in an app whose title or description matches (VoiceOver's view of it).
    let name = args[1], label = args[2].lowercased()
    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) else { print("not running"); break }
    func find(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 40 else { return nil }
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            if let text = value as? String, text.lowercased() == label {
                var role: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                if (role as? String) == "AXButton" || (role as? String) == "AXRadioButton" || (role as? String) == "AXCheckBox" { return element }
            }
        }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        for child in children as? [AXUIElement] ?? [] {
            if let found = find(child, depth: depth + 1) { return found }
        }
        return nil
    }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    var windows: CFTypeRef?
    AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windows)
    var pressed = false
    for window in windows as? [AXUIElement] ?? [] {
        if let button = find(window, depth: 0) {
            print("press:", AXUIElementPerformAction(button, kAXPressAction as CFString).rawValue)
            pressed = true
            break
        }
    }
    if !pressed { print("not found:", label) }
case "axdump":
    // Prints role, name and value of every element whose text contains the filter (all when omitted).
    let name = args[1], filter = args.count > 2 ? args[2].lowercased() : ""
    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) else { print("not running"); break }
    func text(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }
    func dump(_ element: AXUIElement, depth: Int) {
        guard depth < 40 else { return }
        let fields = [text(element, kAXTitleAttribute), text(element, kAXDescriptionAttribute), text(element, kAXValueAttribute)]
        if fields.contains(where: { !$0.isEmpty }), filter.isEmpty || fields.joined(separator: " ").lowercased().contains(filter) {
            print(text(element, kAXRoleAttribute), fields.map { "\"\($0)\"" }.joined(separator: " "))
        }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        for child in children as? [AXUIElement] ?? [] { dump(child, depth: depth + 1) }
    }
    var windows: CFTypeRef?
    AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &windows)
    for window in windows as? [AXUIElement] ?? [] { dump(window, depth: 0) }
case "axclose":
    // Presses the close button of an app's window whose title contains the filter (the first window when omitted).
    // Retries for up to 3 s, since a window that just appeared may not be in the Accessibility tree yet.
    let name = args[1], filter = args.count > 2 ? args[2].lowercased() : ""
    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) else { print("not running"); break }
    var closed = false, seen: [String] = []
    for _ in 0..<15 where !closed {
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &windows)
        seen = []
        for window in windows as? [AXUIElement] ?? [] {
            var title: CFTypeRef?, button: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button)
            let text = (title as? String) ?? ""
            seen.append("\"\(text)\"\(button == nil ? " (no close button)" : "")")
            guard filter.isEmpty || text.lowercased().contains(filter), let button else { continue }
            print("close \(text):", AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString).rawValue)
            closed = true
            break
        }
        if !closed { usleep(200_000) }
    }
    if !closed { print("no closable window; windows seen:", seen.joined(separator: ", ")) }
case "axsetfield":
    // Sets the first text (or secure text) field in an app's windows through Accessibility.
    let name = args[1], value = args[2]
    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) else { print("not running"); break }
    func findField(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 40 else { return nil }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if (role as? String) == "AXTextField" { return element }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        for child in children as? [AXUIElement] ?? [] {
            if let found = findField(child, depth: depth + 1) { return found }
        }
        return nil
    }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    var windows: CFTypeRef?
    AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windows)
    var done = false
    for window in windows as? [AXUIElement] ?? [] {
        if let field = findField(window, depth: 0) {
            print("set:", AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, value as CFString).rawValue)
            done = true
            break
        }
    }
    if !done { print("no field") }
case "pbsave":
    // Saves every item and type on the clipboard, so tests can put it back exactly.
    let items = (NSPasteboard.general.pasteboardItems ?? []).map { item in
        Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type.rawValue, $0) } })
    }
    let data = try! PropertyListSerialization.data(fromPropertyList: items, format: .binary, options: 0)
    try! data.write(to: URL(fileURLWithPath: args[1]))
    print("saved", items.count, "items")
case "pbrestore":
    let data = try! Data(contentsOf: URL(fileURLWithPath: args[1]))
    let items = try! PropertyListSerialization.propertyList(from: data, format: nil) as! [[String: Data]]
    NSPasteboard.general.clearContents()
    let restored = items.map { dict -> NSPasteboardItem in
        let item = NSPasteboardItem()
        for (type, value) in dict { item.setData(value, forType: NSPasteboard.PasteboardType(type)) }
        return item
    }
    NSPasteboard.general.writeObjects(restored)
    print("restored", restored.count, "items")
default:
    print("usage: key|type|move|click|drag|windows|frame|pasteboard|pbsave|pbrestore")
}
