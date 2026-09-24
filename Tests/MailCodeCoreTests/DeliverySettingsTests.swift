import Foundation
import Testing

@testable import MailCodeCore

@MainActor
struct DeliverySettingsTests {
    @Test func defaultsPersistenceAndDurationPolicy() throws {
        let name = "MailCodeFiller.settings.tests.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let settings = DeliverySettings(preferences: preferences)
        #expect(settings.notificationSeconds == 30)
        #expect(!settings.automaticallyCopy)
        #expect(settings.cardPlacementMode == .followMouse)
        #expect(!settings.rememberDraggedPosition)
        #expect(!settings.allowsScreenshots)
        #expect(settings.rememberedCardPositions.isEmpty)
        #expect(settings.cardClickAction == .copy)
        #expect(settings.actionForCodeCard(writableTargetAvailable: false) == .copy)
        #expect(settings.actionForCodeCard(writableTargetAvailable: true) == .copy)
        #expect(!settings.jevEnabled)
        #expect(settings.fillShortcut == .defaultFill)
        #expect(settings.chooserShortcut == .defaultChooser)
        #expect(!settings.allowsBrowserAutomation)
        #expect(!settings.otpFieldAutoTriggerEnabled)
        #expect(!settings.otpFieldRequireAuthPage)
        #expect(!settings.clipboardAutoClearEnabled)
        #expect(settings.clipboardAutoClearSeconds == 30)
        #expect(settings.displayDuration(automaticallyCopied: false) == 30)
        #expect(settings.displayDuration(automaticallyCopied: true) == 30)
        try settings.setDisplayDuration("45")
        #expect(throws: NotificationSettingsError.invalidDuration) { try settings.setDisplayDuration("4") }
        #expect(settings.notificationSeconds == 45)
        settings.automaticallyCopy = true
        settings.cardClickAction = .fill
        settings.cardPlacementMode = .followInputCaret
        settings.rememberDraggedPosition = true
        settings.allowsScreenshots = true
        let customFill = ShortcutBinding(keyCode: 8, modifiers: ShortcutBinding.control)
        let customChooser = ShortcutBinding(keyCode: 49, modifiers: ShortcutBinding.command)
        settings.fillShortcut = customFill
        settings.chooserShortcut = customChooser
        settings.allowsBrowserAutomation = true
        settings.otpFieldAutoTriggerEnabled = true
        settings.otpFieldRequireAuthPage = true
        settings.clipboardAutoClearEnabled = true
        settings.clipboardAutoClearSeconds = 120
        settings.rememberCardPosition(
            RememberedCardPosition(screenIdentifier: "display-1", xOffset: 120, yOffset: 80))
        #expect(settings.actionForCodeCard(writableTargetAvailable: false) == .copy)
        #expect(settings.actionForCodeCard(writableTargetAvailable: true) == .fill)
        #expect(settings.displayDuration(automaticallyCopied: true) == 45)
        let restored = DeliverySettings(preferences: preferences)
        #expect(restored.notificationSeconds == 45)
        #expect(restored.automaticallyCopy)
        #expect(restored.cardClickAction == .fill)
        #expect(restored.cardPlacementMode == .followInputCaret)
        #expect(restored.rememberDraggedPosition)
        #expect(restored.allowsScreenshots)
        #expect(restored.fillShortcut == customFill)
        #expect(restored.chooserShortcut == customChooser)
        #expect(restored.allowsBrowserAutomation)
        #expect(restored.otpFieldAutoTriggerEnabled)
        #expect(restored.otpFieldRequireAuthPage)
        #expect(restored.clipboardAutoClearEnabled)
        #expect(restored.clipboardAutoClearSeconds == 120)
        #expect(
            restored.rememberedCardPositions == [
                RememberedCardPosition(screenIdentifier: "display-1", xOffset: 120, yOffset: 80)
            ])
        #expect(restored.actionForCodeCard(writableTargetAvailable: false) == .copy)
        #expect(restored.actionForCodeCard(writableTargetAvailable: true) == .fill)
        settings.notificationSeconds = -1
        #expect(settings.notificationSeconds == 5)
        settings.notificationSeconds = 900
        #expect(settings.notificationSeconds == 300)
    }

    @Test func invalidClipboardDurationAndConflictingStoredBindingsUseDefaults() throws {
        let name = "MailCodeFiller.new-settings.tests.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        ShortcutBinding.defaultFill.save(to: preferences, key: ShortcutSettingsKeys.fill)
        ShortcutBinding.defaultFill.save(to: preferences, key: ShortcutSettingsKeys.chooser)
        preferences.set(5, forKey: "clipboard-auto-clear-seconds")
        let settings = DeliverySettings(preferences: preferences)
        #expect(settings.fillShortcut == .defaultFill)
        #expect(settings.chooserShortcut == .defaultChooser)
        #expect(settings.clipboardAutoClearSeconds == 30)
        settings.clipboardAutoClearSeconds = 45
        #expect(settings.clipboardAutoClearSeconds == 30)
    }

    @Test func rememberedPositionsAreUniqueByScreenAndCanBeReset() throws {
        let name = "MailCodeFiller.position-settings.tests.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let settings = DeliverySettings(preferences: preferences)
        settings.rememberCardPosition(
            RememberedCardPosition(screenIdentifier: "display-1", xOffset: 20, yOffset: 30))
        settings.rememberCardPosition(
            RememberedCardPosition(screenIdentifier: "display-2", xOffset: 40, yOffset: 50))
        settings.rememberCardPosition(
            RememberedCardPosition(screenIdentifier: "display-1", xOffset: 60, yOffset: 70))

        #expect(settings.rememberedCardPositions.count == 2)
        #expect(settings.rememberedCardPosition(for: "display-1")?.xOffset == 60)
        #expect(settings.rememberedCardPosition(for: "display-2")?.yOffset == 50)
        settings.rememberDraggedPosition = false
        let restored = DeliverySettings(preferences: preferences)
        #expect(!restored.rememberDraggedPosition)
        #expect(restored.rememberedCardPositions == settings.rememberedCardPositions)
        settings.resetRememberedCardPositions()
        #expect(settings.rememberedCardPositions.isEmpty)
        #expect(DeliverySettings(preferences: preferences).rememberedCardPositions.isEmpty)
    }

    @Test func doNotDisturbPersistsUntilItsEndAndExpiredDatesRestoreAsOff() throws {
        let name = "MailCodeFiller.quiet.tests.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Singapore"))
        let now = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026, month: 9, day: 23, hour: 15, minute: 10)))
        let settings = DeliverySettings(preferences: preferences, now: now)
        settings.setDoNotDisturb(.oneHour, now: now, calendar: calendar)
        let period = try #require(settings.doNotDisturbPeriod)
        #expect(period.endsAt == now.addingTimeInterval(3600))
        #expect(preferences.object(forKey: "do-not-disturb-ends-at") as? Date == period.endsAt)

        let restored = DeliverySettings(preferences: preferences, now: now + 30)
        #expect(restored.doNotDisturbPeriod == period)
        let expired = DeliverySettings(preferences: preferences, now: period.endsAt! + 1)
        #expect(expired.doNotDisturbPeriod == nil)
        #expect(preferences.object(forKey: "do-not-disturb-ends-at") == nil)
    }

    @Test func tomorrowMorningUsesTheInjectedLocalCalendar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Singapore"))
        let now = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026, month: 9, day: 23, hour: 20, minute: 45)))
        let period = DoNotDisturbPeriod.starting(.tomorrowMorning, at: now, calendar: calendar)
        let end = try #require(period.endsAt)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: end)
        #expect(components.year == 2026)
        #expect(components.month == 9)
        #expect(components.day == 24)
        #expect(components.hour == 8)
        #expect(components.minute == 0)
    }
}
