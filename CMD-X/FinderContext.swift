import AppKit
import ApplicationServices

enum FinderContext {
    /// Fail open: an unrecognised focus leaves the original shortcut untouched.
    static func hasFileFocus() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "com.apple.finder" else { return false }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.025)
        guard var element = elementAttribute(application, kAXFocusedUIElementAttribute) else { return false }

        if let window = elementAttribute(application, kAXFocusedWindowAttribute) {
            let subrole = stringAttribute(window, kAXSubroleAttribute)
            if subrole == kAXDialogSubrole || subrole == kAXSystemDialogSubrole { return false }
            if let modal = attribute(window, kAXModalAttribute) as? Bool, modal { return false }
            if let sheets = attribute(window, kAXSheetsAttribute) as? [AXUIElement], !sheets.isEmpty { return false }
        }

        let fileRoles: Set<String> = ["AXBrowser", "AXOutline", "AXTable", "AXList", "AXScrollArea", "AXLayoutArea"]
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        var isFileView = false
        let deadline = ProcessInfo.processInfo.systemUptime + 0.08
        for _ in 0..<12 {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  let role = stringAttribute(element, kAXRoleAttribute) else { return false }
            if textRoles.contains(role) || role == "AXSheet" || role == "AXMenu" { return false }
            // Covers editable names even if Finder changes their accessibility role.
            if attribute(element, kAXSelectedTextRangeAttribute) != nil { return false }
            isFileView = isFileView || fileRoles.contains(role)
            if role == kAXWindowRole || role == kAXApplicationRole { return isFileView }
            guard let parent = elementAttribute(element, kAXParentAttribute) else { return isFileView }
            element = parent
        }
        return false
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
