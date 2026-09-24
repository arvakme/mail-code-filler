import Foundation

/// UserDefaults keys used by DeliverySettings. Bindings are JSON-encoded Data.
public enum ShortcutSettingsKeys {
    public static let fill = "shortcut-fill-binding"
    public static let chooser = "shortcut-chooser-binding"
    public static let browserAutomation = "allow-browser-automation"
}

public struct ShortcutBinding: Codable, Equatable, Hashable, Sendable {
    // Carbon modifiers; storing key code and modifier bits avoids layout-dependent text.
    public static let command: UInt32 = 1 << 8
    public static let shift: UInt32 = 1 << 9
    public static let option: UInt32 = 1 << 11
    public static let control: UInt32 = 1 << 12
    public static let supportedModifiers = command | shift | option | control

    public static let defaultFill = ShortcutBinding(keyCode: 9, modifiers: control | option)  // V
    public static let defaultChooser = ShortcutBinding(keyCode: 49, modifiers: control | option)  // Space

    public let keyCode: UInt16
    public let modifiers: UInt32

    public init(keyCode: UInt16, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var isValid: Bool {
        keyCode < 128 && modifiers & ~Self.supportedModifiers == 0
            && modifiers & (Self.control | Self.command) != 0
            && ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode)
    }

    public func conflicts(with other: ShortcutBinding) -> Bool { self == other }

    public var displayName: String {
        let symbols = [
            modifiers & Self.control != 0 ? "⌃" : "",
            modifiers & Self.option != 0 ? "⌥" : "",
            modifiers & Self.shift != 0 ? "⇧" : "",
            modifiers & Self.command != 0 ? "⌘" : "",
        ].joined()
        let key =
            switch keyCode {
            case 49: "Space"
            case 36: "Return"
            case 48: "Tab"
            case 53: "Esc"
            case 9: "V"
            default: "Key \(keyCode)"
            }
        return symbols + key
    }

    public static func load(from defaults: UserDefaults, key: String, fallback: ShortcutBinding)
        -> ShortcutBinding
    {
        guard let data = defaults.data(forKey: key),
            let binding = try? JSONDecoder().decode(ShortcutBinding.self, from: data),
            binding.isValid
        else { return fallback }
        return binding
    }

    public func save(to defaults: UserDefaults, key: String) {
        guard isValid, let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: key)
    }
}
