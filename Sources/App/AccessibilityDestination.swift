import AppKit
import ApplicationServices
import MailCodeCore

@MainActor
final class AccessibilityDestination: FillDestination {
    enum Failure: LocalizedError, Equatable {
        case permission, noTarget, unsupported, changed, writeFailed, unverified

        var errorDescription: String? {
            switch self {
            case .permission: "辅助功能尚未授权。查看和显式复制仍可使用。"
            case .noTarget: "请先将光标放到其他 App 的验证码输入框，再按快捷键。"
            case .unsupported: "这个控件暂不支持安全插入，请显式复制。"
            case .changed: "输入目标或选区已改变，已停止。请重新按快捷键。"
            case .writeFailed: "控件未确认插入。请先检查输入框；不会自动重试。"
            case .unverified: "已请求插入，但无法核实结果。请检查输入框；不会自动重试。"
            }
        }
    }

    struct FocusedTextTarget {
        let bounds: CGRect?
    }

    let application: NSRunningApplication
    private let appElement: AXUIElement
    private let element: AXUIElement
    private let original: String
    private let selection: CFRange

    init() throws {
        guard AXIsProcessTrusted() else { throw Failure.permission }
        guard let application = NSWorkspace.shared.frontmostApplication,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            throw Failure.noTarget
        }
        self.application = application
        appElement = AXUIElementCreateApplication(application.processIdentifier)
        element = try Self.writableTextElement(in: appElement)
        original = try Self.text(in: element)
        selection = try Self.selectedRange(in: element)
    }

    static func focusedTextTarget() -> FocusedTextTarget? {
        guard AXIsProcessTrusted(),
            let application = NSWorkspace.shared.frontmostApplication,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let element = try? writableTextElement(in: appElement) else { return nil }
        return FocusedTextTarget(bounds: cocoaBounds(of: element))
    }

    /// Where to place the card when no writable field is focused: a readable caret or a
    /// field-sized focused element, else the mouse pointer. Read-only; Cocoa coordinates.
    static func placementAnchor() -> CGRect {
        let mouse = NSEvent.mouseLocation
        let pointer = CGRect(x: mouse.x, y: mouse.y - 16, width: 1, height: 16)
        guard AXIsProcessTrusted(),
            let application = NSWorkspace.shared.frontmostApplication,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
            let element = try? focusedElement(in: AXUIElementCreateApplication(application.processIdentifier))
        else { return pointer }
        if let caret = caretBounds(of: element) { return cocoaRect(caret) ?? pointer }
        if let field = elementBounds(of: element), field.height <= 120 { return cocoaRect(field) ?? pointer }
        return pointer
    }

    func insert(_ code: String) throws {
        guard AXIsProcessTrusted() else { throw Failure.permission }
        guard !application.isTerminated,
            NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
            CFEqual(try Self.focusedElement(in: appElement), element),
            try Self.text(in: element) == original
        else { throw Failure.changed }
        let current = try Self.selectedRange(in: element)
        guard current.location == selection.location, current.length == selection.length else {
            throw Failure.changed
        }
        let expected = (original as NSString).replacingCharacters(
            in: NSRange(location: selection.location, length: selection.length), with: code
        )
        let result = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, code as CFString)
        guard result == .success else { throw Failure.writeFailed }
        do {
            guard try Self.text(in: element) == expected else { throw Failure.unverified }
        } catch { throw Failure.unverified }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if result == .attributeUnsupported { return nil }
        guard result == .success else { throw Failure.unsupported }
        return value
    }

    private static func focusedElement(in app: AXUIElement) throws -> AXUIElement {
        guard let value = try attribute(app, kAXFocusedUIElementAttribute),
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { throw Failure.noTarget }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func writableTextElement(in app: AXUIElement) throws -> AXUIElement {
        let element = try focusedElement(in: app)
        let role = try attribute(element, kAXRoleAttribute) as? String
        let subrole = try attribute(element, kAXSubroleAttribute) as? String
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
            subrole != kAXSecureTextFieldSubrole
        else { throw Failure.unsupported }

        var writable = DarwinBoolean(false)
        guard
            AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &writable)
                == .success,
            writable.boolValue
        else { throw Failure.unsupported }
        _ = try text(in: element)
        _ = try selectedRange(in: element)
        return element
    }

    private static func cocoaBounds(of element: AXUIElement) -> CGRect? {
        (caretBounds(of: element) ?? elementBounds(of: element)).flatMap(cocoaRect)
    }

    private static func cocoaRect(_ axBounds: CGRect) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let bounds = CGRect(
            x: axBounds.minX, y: primary.frame.maxY - axBounds.maxY,
            width: max(1, axBounds.width), height: max(1, axBounds.height))
        guard bounds.minX.isFinite, bounds.minY.isFinite,
            bounds.width.isFinite, bounds.height.isFinite
        else { return nil }
        return bounds
    }

    private static func caretBounds(of element: AXUIElement) -> CGRect? {
        guard var range = try? selectedRange(in: element) else { return nil }
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &value)
                == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgRect else { return nil }
        var bounds = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &bounds), isUsable(bounds) else { return nil }
        return bounds
    }

    private static func elementBounds(of element: AXUIElement) -> CGRect? {
        guard let position = pointValue(element, kAXPositionAttribute),
            let size = sizeValue(element, kAXSizeAttribute)
        else { return nil }
        let bounds = CGRect(origin: position, size: size)
        return isUsable(bounds) ? bounds : nil
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite
            && rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width >= 0 && rect.height > 0
    }

    private static func pointValue(_ element: AXUIElement, _ name: String) -> CGPoint? {
        guard let value = axValue(element, name), AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeValue(_ element: AXUIElement, _ name: String) -> CGSize? {
        guard let value = axValue(element, name), AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private static func axValue(_ element: AXUIElement, _ name: String) -> AXValue? {
        do {
            guard let value = try attribute(element, name),
                CFGetTypeID(value) == AXValueGetTypeID()
            else { return nil }
            return unsafeDowncast(value, to: AXValue.self)
        } catch { return nil }
    }

    private static func text(in element: AXUIElement) throws -> String {
        guard let text = try attribute(element, kAXValueAttribute) as? String else {
            throw Failure.unsupported
        }
        return text
    }

    private static func selectedRange(in element: AXUIElement) throws -> CFRange {
        guard let value = try attribute(element, kAXSelectedTextRangeAttribute),
            CFGetTypeID(value) == AXValueGetTypeID()
        else { throw Failure.unsupported }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range),
            range.location >= 0, range.length >= 0
        else { throw Failure.unsupported }
        let length = try text(in: element).utf16.count
        guard range.location <= length, range.length <= length - range.location else {
            throw Failure.unsupported
        }
        return range
    }
}
