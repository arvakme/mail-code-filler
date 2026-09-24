import AppKit
import ApplicationServices
import MailCodeCore
import ScriptingBridge

/// Reads only the frontmost browser window, on demand. Raw URLs stay on the stack.
@MainActor
final class BrowserActivePageProvider: ActivePageProviding {
    private let allowsAutomation: () -> Bool
    private static let browserIDs: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "org.mozilla.firefox",
    ]

    init(allowsAutomation: @escaping () -> Bool = { false }) {
        self.allowsAutomation = allowsAutomation
    }

    func currentPage() -> ActivePage? {
        guard let app = NSWorkspace.shared.frontmostApplication,
            let bundleID = app.bundleIdentifier,
            Self.browserIDs.contains(bundleID), !app.isTerminated
        else { return nil }
        if AXIsProcessTrusted(),
            let url = Self.accessibilityURL(processID: app.processIdentifier),
            let page = ActivePage.fromBrowserURL(url)
        {
            return page
        }
        guard allowsAutomation(),
            ["com.apple.Safari", "com.google.Chrome"].contains(bundleID),
            NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
            let url = Self.automationURL(processID: app.processIdentifier, bundleID: bundleID),
            !app.isTerminated,
            NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        else { return nil }
        return ActivePage.fromBrowserURL(url)
    }

    private static func accessibilityURL(processID: pid_t) -> URL? {
        let app = AXUIElementCreateApplication(processID)
        var rawWindow: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &rawWindow) == .success,
            let rawWindow, CFGetTypeID(rawWindow) == AXUIElementGetTypeID()
        else { return nil }
        var pending = [unsafeDowncast(rawWindow, to: AXUIElement.self)]
        var inspected = 0
        while !pending.isEmpty && inspected < 200 {
            let element = pending.removeLast()
            inspected += 1
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success
            else { continue }
            if role as? String == "AXWebArea" {
                for key in [kAXURLAttribute as String, kAXDocumentAttribute as String] {
                    var raw: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, key as CFString, &raw) == .success,
                        let raw, let url = url(raw)
                    {
                        return url
                    }
                }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
                == .success,
                let values = children as? [AXUIElement]
            {
                pending.append(contentsOf: values)
            }
        }
        return nil
    }

    private static func url(_ raw: CFTypeRef) -> URL? {
        if let value = raw as? URL { return value }
        if let value = raw as? String { return URL(string: value) }
        return nil
    }

    private static func automationURL(processID: pid_t, bundleID: String) -> URL? {
        // ScriptingBridge targets the already-running PID; it never opens a browser by name.
        guard let app = SBApplication(processIdentifier: processID), app.isRunning else { return nil }
        let window = app.value(forKey: "frontWindow") as? NSObject
        let tabKey = bundleID == "com.apple.Safari" ? "currentTab" : "activeTab"
        guard let tab = window?.value(forKey: tabKey) as? NSObject,
            let value = tab.value(forKey: "URL") as? String
        else { return nil }
        return URL(string: value)
    }
}
