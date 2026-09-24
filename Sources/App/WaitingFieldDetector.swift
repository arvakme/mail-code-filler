import AppKit
import ApplicationServices
import MailCodeCore

/// Reads only the focused element's type and four label attributes, never its value.
@MainActor
enum WaitingFieldDetector {
    static func focusedFieldMatches(requireAuthPage: Bool, looksLikeAuthPage: Bool) -> Bool {
        guard AXIsProcessTrusted(),
            let application = NSWorkspace.shared.frontmostApplication,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return false }

        let app = AXUIElementCreateApplication(application.processIdentifier)
        guard let focused = attribute(app, kAXFocusedUIElementAttribute as CFString),
            CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return false }
        let field = unsafeDowncast(focused, to: AXUIElement.self)
        let role = attribute(field, kAXRoleAttribute as CFString) as? String
        guard role == kAXTextFieldRole as String else { return false }
        let subrole = attribute(field, kAXSubroleAttribute as CFString) as? String
        guard subrole != kAXSecureTextFieldSubrole as String else { return false }
        let labels = [
            kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute,
            kAXPlaceholderValueAttribute,
        ].compactMap { attribute(field, $0 as CFString) as? String }
        return WaitingFieldRule.matches(
            role: role, subrole: subrole, labels: labels,
            looksLikeAuthPage: looksLikeAuthPage, requireAuthPage: requireAuthPage)
    }

    private static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }
}
