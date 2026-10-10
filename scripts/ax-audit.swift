// Lists interactive elements in Tutto's open windows that VoiceOver would announce without a name.
//   swift scripts/ax-audit.swift            (needs Accessibility for the process running it)
import AppKit

let interactive: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXPopUpButton",
                                "AXMenuButton", "AXTextField", "AXIncrementor", "AXSwitch"]
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "Tutto" }) else {
    print("Tutto isn't running"); exit(1)
}
func string(_ element: AXUIElement, _ attribute: String) -> String {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    return (value as? String) ?? ""
}
var total = 0, unlabeled: [String] = []
func walk(_ element: AXUIElement, path: String, depth: Int) {
    guard depth < 40 else { return }
    let role = string(element, kAXRoleAttribute)
    let subrole = string(element, kAXSubroleAttribute)
    if interactive.contains(role), !["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"].contains(subrole) {
        total += 1
        let name = [string(element, kAXTitleAttribute), string(element, kAXDescriptionAttribute),
                    string(element, kAXHelpAttribute), string(element, "AXPlaceholderValue")].first { !$0.isEmpty }
        if name == nil { unlabeled.append("\(path) › \(role)") }
    }
    var children: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
    let label = string(element, kAXTitleAttribute).isEmpty ? role : string(element, kAXTitleAttribute)
    for child in children as? [AXUIElement] ?? [] { walk(child, path: "\(path) › \(label)", depth: depth + 1) }
}
let root = AXUIElementCreateApplication(app.processIdentifier)
var windows: CFTypeRef?
AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windows)
for window in windows as? [AXUIElement] ?? [] {
    walk(window, path: string(window, kAXTitleAttribute).isEmpty ? "window" : string(window, kAXTitleAttribute), depth: 0)
}
print("interactive elements: \(total), unlabeled: \(unlabeled.count)")
unlabeled.prefix(40).forEach { print("  -", $0) }
