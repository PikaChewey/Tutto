// Drives Tutto for live tests by posting real keyboard and mouse events.
//
//   swift scripts/drive.swift key cmd+shift+2          press a shortcut
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
    "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
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

func type(_ text: String) {
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
case "type":
    type(args.dropFirst().joined(separator: " "))
case "move":
    mouse(.mouseMoved, CGPoint(x: Double(args[1])!, y: Double(args[2])!))
case "click":
    let point = CGPoint(x: Double(args[1])!, y: Double(args[2])!)
    mouse(.mouseMoved, point); usleep(50_000)
    mouse(.leftMouseDown, point); usleep(40_000)
    mouse(.leftMouseUp, point)
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
