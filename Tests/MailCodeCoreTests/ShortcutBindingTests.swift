import Foundation
import Testing

@testable import MailCodeCore

struct ShortcutBindingTests {
    @Test func defaultsAreDistinctAndValid() {
        #expect(ShortcutBinding.defaultFill.isValid)
        #expect(ShortcutBinding.defaultChooser.isValid)
        #expect(!ShortcutBinding.defaultFill.conflicts(with: .defaultChooser))
        #expect(ShortcutBinding.defaultFill.displayName == "⌃⌥V")
        #expect(ShortcutBinding.defaultChooser.displayName == "⌃⌥Space")
    }

    @Test func requiresCommandOrControl() {
        #expect(!ShortcutBinding(keyCode: 9, modifiers: ShortcutBinding.option).isValid)
        #expect(!ShortcutBinding(keyCode: 255, modifiers: ShortcutBinding.command).isValid)
        #expect(ShortcutBinding(keyCode: 9, modifiers: ShortcutBinding.command).isValid)
    }

    @Test func storesKeyCodeAndModifiers() throws {
        let suite = "ShortcutBindingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let custom = ShortcutBinding(keyCode: 42, modifiers: ShortcutBinding.command | ShortcutBinding.shift)
        custom.save(to: defaults, key: ShortcutSettingsKeys.fill)
        #expect(
            ShortcutBinding.load(
                from: defaults, key: ShortcutSettingsKeys.fill,
                fallback: .defaultFill) == custom)
        #expect(
            ShortcutBinding.load(
                from: defaults, key: ShortcutSettingsKeys.chooser,
                fallback: .defaultChooser) == .defaultChooser)
    }
}
