import AppKit
import ApplicationServices

enum FinderContext {
    struct Inspection {
        let isFileView: Bool
        let detail: String
    }

    /// Called after the event tap returns, so Finder can answer AX requests.
    static func inspectFileFocus() -> Inspection {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "com.apple.finder" else {
            return Inspection(isFileView: false, detail: "Finder is not frontmost")
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.025)
        var focusedValue: CFTypeRef?
        let focusError = AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focusedValue)
        guard focusError == .success, let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return Inspection(isFileView: false, detail: "focused element unavailable; AXError=\(focusError.rawValue)")
        }
        var element = focusedValue as! AXUIElement
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        if let window = elementAttribute(application, kAXFocusedWindowAttribute) {
            let subrole = stringAttribute(window, kAXSubroleAttribute)
            if subrole == kAXDialogSubrole || subrole == kAXSystemDialogSubrole {
                return Inspection(isFileView: false, detail: "dialog window")
            }
            if let modal = attribute(window, kAXModalAttribute) as? Bool, modal {
                return Inspection(isFileView: false, detail: "modal window")
            }
            if let children = attribute(window, kAXChildrenAttribute) as? [AXUIElement] {
                for child in children {
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        return Inspection(isFileView: false, detail: "window inspection deadline")
                    }
                    if stringAttribute(child, kAXRoleAttribute) == kAXSheetRole {
                        return Inspection(isFileView: false, detail: "attached sheet")
                    }
                }
            }
        }

        let fileRoles: Set<String> = ["AXBrowser", "AXOutline", "AXTable", "AXList", "AXScrollArea", "AXLayoutArea"]
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        var roles: [String] = []
        for _ in 0..<12 {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                return Inspection(isFileView: false, detail: "focus deadline; roles=\(roles.joined(separator: "/"))")
            }
            guard let role = stringAttribute(element, kAXRoleAttribute) else {
                return Inspection(isFileView: false, detail: "role unavailable; roles=\(roles.joined(separator: "/"))")
            }
            roles.append(role)
            let trace = roles.joined(separator: "/")
            if textRoles.contains(role) || role == kAXSheetRole || role == "AXMenu" {
                return Inspection(isFileView: false, detail: "text/dialog/menu focus; roles=\(trace)")
            }
            // File views can expose readable text-selection metadata without being
            // text editors. Stop at the confirmed file view instead of rejecting it.
            if fileRoles.contains(role) {
                return Inspection(isFileView: true, detail: "file view; roles=\(trace)")
            }
            if attribute(element, kAXSelectedTextRangeAttribute) != nil {
                var editable = DarwinBoolean(false)
                let result = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &editable)
                if result == .success && editable.boolValue {
                    return Inspection(isFileView: false, detail: "editable value; roles=\(trace)")
                }
            }
            if role == kAXWindowRole || role == kAXApplicationRole {
                return Inspection(isFileView: false, detail: "unrecognised file view; roles=\(trace)")
            }
            guard let parent = elementAttribute(element, kAXParentAttribute) else {
                return Inspection(isFileView: false, detail: "no file-view ancestor; roles=\(trace)")
            }
            element = parent
        }
        return Inspection(isFileView: false, detail: "ancestor limit; roles=\(roles.joined(separator: "/"))")
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
