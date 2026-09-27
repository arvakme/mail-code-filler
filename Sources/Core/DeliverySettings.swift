import Foundation
import Observation

public enum LinkCardLevel: String, CaseIterable, Sendable {
    case signInAndVerification
    case includingAccountNotices

    public func allows(_ purpose: SignInLink.Purpose) -> Bool {
        purpose != .accountNotice || self == .includingAccountNotices
    }
}

@MainActor @Observable
public final class DeliverySettings {
    public static let notificationRange = 5...300
    private let preferences: UserDefaults
    public var cardClickAction: CodeCardClickAction {
        didSet { preferences.set(cardClickAction.rawValue, forKey: "code-card-click-action") }
    }
    public var linkCardLevel: LinkCardLevel {
        didSet { preferences.set(linkCardLevel.rawValue, forKey: "link-card-level") }
    }
    public var checksJunkFolder: Bool {
        didSet { preferences.set(checksJunkFolder, forKey: "checks-junk-folder") }
    }
    public var automaticallyCopy: Bool {
        didSet { preferences.set(automaticallyCopy, forKey: "automatically-copy-code") }
    }
    public var cardPlacementMode: CardPlacementMode {
        didSet { preferences.set(cardPlacementMode.rawValue, forKey: "arrival-card-placement-mode") }
    }
    public var rememberDraggedPosition: Bool {
        didSet { preferences.set(rememberDraggedPosition, forKey: "remember-arrival-card-position") }
    }
    public var allowsScreenshots: Bool {
        didSet { preferences.set(allowsScreenshots, forKey: "allow-arrival-card-screenshots") }
    }
    public private(set) var rememberedCardPositions: [RememberedCardPosition] {
        didSet { persistRememberedCardPositions() }
    }
    public var notificationSeconds: Int {
        didSet {
            let bounded = min(
                max(notificationSeconds, Self.notificationRange.lowerBound), Self.notificationRange.upperBound
            )
            if notificationSeconds != bounded {
                notificationSeconds = bounded
                return
            }
            preferences.set(notificationSeconds, forKey: "notification-seconds")
        }
    }
    public var jevEnabled: Bool {
        didSet { preferences.set(jevEnabled, forKey: "jev-enabled") }
    }
    public var fillShortcut: ShortcutBinding {
        didSet { fillShortcut.save(to: preferences, key: ShortcutSettingsKeys.fill) }
    }
    public var chooserShortcut: ShortcutBinding {
        didSet { chooserShortcut.save(to: preferences, key: ShortcutSettingsKeys.chooser) }
    }
    public var allowsBrowserAutomation: Bool {
        didSet { preferences.set(allowsBrowserAutomation, forKey: ShortcutSettingsKeys.browserAutomation) }
    }
    public var otpFieldAutoTriggerEnabled: Bool {
        didSet { preferences.set(otpFieldAutoTriggerEnabled, forKey: "otp-field-auto-trigger-enabled") }
    }
    public var otpFieldRequireAuthPage: Bool {
        didSet { preferences.set(otpFieldRequireAuthPage, forKey: "otp-field-require-auth-page") }
    }
    public var clipboardAutoClearEnabled: Bool {
        didSet { preferences.set(clipboardAutoClearEnabled, forKey: "clipboard-auto-clear-enabled") }
    }
    public var clipboardAutoClearSeconds: Int {
        didSet {
            if !Self.clipboardAutoClearChoices.contains(clipboardAutoClearSeconds) {
                clipboardAutoClearSeconds = 30
                return
            }
            preferences.set(clipboardAutoClearSeconds, forKey: "clipboard-auto-clear-seconds")
        }
    }
    public static let clipboardAutoClearChoices = [30, 60, 120]
    public private(set) var doNotDisturbPeriod: DoNotDisturbPeriod? {
        didSet { persistDoNotDisturbPeriod() }
    }

    public init(preferences: UserDefaults = .standard, now: Date = Date()) {
        self.preferences = preferences
        preferences.register(defaults: ["notification-seconds": 30])
        cardClickAction =
            CodeCardClickAction(
                rawValue: preferences.string(forKey: "code-card-click-action") ?? "copy") ?? .copy
        linkCardLevel =
            LinkCardLevel(rawValue: preferences.string(forKey: "link-card-level") ?? "")
            ?? .signInAndVerification
        checksJunkFolder = preferences.bool(forKey: "checks-junk-folder")
        automaticallyCopy = preferences.bool(forKey: "automatically-copy-code")
        cardPlacementMode =
            CardPlacementMode(
                rawValue: preferences.string(forKey: "arrival-card-placement-mode") ?? "followMouse")
            ?? .followMouse
        rememberDraggedPosition = preferences.bool(forKey: "remember-arrival-card-position")
        allowsScreenshots = preferences.bool(forKey: "allow-arrival-card-screenshots")
        rememberedCardPositions = Self.loadRememberedCardPositions(from: preferences)
        notificationSeconds = min(
            max(preferences.integer(forKey: "notification-seconds"), Self.notificationRange.lowerBound),
            Self.notificationRange.upperBound)
        jevEnabled = preferences.bool(forKey: "jev-enabled")
        let storedFill = ShortcutBinding.load(
            from: preferences, key: ShortcutSettingsKeys.fill, fallback: .defaultFill)
        let storedChooser = ShortcutBinding.load(
            from: preferences, key: ShortcutSettingsKeys.chooser, fallback: .defaultChooser)
        fillShortcut = storedFill.conflicts(with: storedChooser) ? .defaultFill : storedFill
        chooserShortcut = storedFill.conflicts(with: storedChooser) ? .defaultChooser : storedChooser
        allowsBrowserAutomation = preferences.bool(forKey: ShortcutSettingsKeys.browserAutomation)
        otpFieldAutoTriggerEnabled = preferences.bool(forKey: "otp-field-auto-trigger-enabled")
        otpFieldRequireAuthPage = preferences.bool(forKey: "otp-field-require-auth-page")
        clipboardAutoClearEnabled = preferences.bool(forKey: "clipboard-auto-clear-enabled")
        let clearSeconds = preferences.integer(forKey: "clipboard-auto-clear-seconds")
        clipboardAutoClearSeconds = Self.clipboardAutoClearChoices.contains(clearSeconds) ? clearSeconds : 30
        if let rawChoice = preferences.string(forKey: "do-not-disturb-choice"),
            let choice = DoNotDisturbChoice(rawValue: rawChoice),
            let startedAt = preferences.object(forKey: "do-not-disturb-started-at") as? Date
        {
            let endsAt = preferences.object(forKey: "do-not-disturb-ends-at") as? Date
            let restored = DoNotDisturbPeriod(
                choice: choice, startedAt: startedAt, endsAt: endsAt)
            doNotDisturbPeriod = restored.isActive(at: now) ? restored : nil
        } else {
            doNotDisturbPeriod = nil
        }
        if doNotDisturbPeriod == nil {
            preferences.removeObject(forKey: "do-not-disturb-choice")
            preferences.removeObject(forKey: "do-not-disturb-started-at")
            preferences.removeObject(forKey: "do-not-disturb-ends-at")
        }
    }

    public func setDoNotDisturb(
        _ choice: DoNotDisturbChoice, now: Date = Date(), calendar: Calendar = .current
    ) {
        doNotDisturbPeriod = .starting(choice, at: now, calendar: calendar)
    }

    public func resumeDoNotDisturb() {
        doNotDisturbPeriod = nil
    }

    public func rememberCardPosition(_ position: RememberedCardPosition) {
        rememberedCardPositions.removeAll { $0.screenIdentifier == position.screenIdentifier }
        rememberedCardPositions.append(position)
    }

    public func rememberedCardPosition(for screenIdentifier: String) -> RememberedCardPosition? {
        rememberedCardPositions.first { $0.screenIdentifier == screenIdentifier }
    }

    public func resetRememberedCardPositions() {
        rememberedCardPositions = []
    }

    public func recalculateDoNotDisturb(using calendar: Calendar) {
        guard let period = doNotDisturbPeriod, period.choice == .tomorrowMorning else { return }
        doNotDisturbPeriod = period.recalculated(using: calendar)
    }

    private func persistDoNotDisturbPeriod() {
        guard let period = doNotDisturbPeriod else {
            preferences.removeObject(forKey: "do-not-disturb-choice")
            preferences.removeObject(forKey: "do-not-disturb-started-at")
            preferences.removeObject(forKey: "do-not-disturb-ends-at")
            return
        }
        preferences.set(period.choice.rawValue, forKey: "do-not-disturb-choice")
        preferences.set(period.startedAt, forKey: "do-not-disturb-started-at")
        if let endsAt = period.endsAt {
            preferences.set(endsAt, forKey: "do-not-disturb-ends-at")
        } else {
            preferences.removeObject(forKey: "do-not-disturb-ends-at")
        }
    }

    private static func loadRememberedCardPositions(from preferences: UserDefaults)
        -> [RememberedCardPosition]
    {
        guard let data = preferences.data(forKey: "arrival-card-positions") else { return [] }
        return (try? JSONDecoder().decode([RememberedCardPosition].self, from: data)) ?? []
    }

    private func persistRememberedCardPositions() {
        guard let data = try? JSONEncoder().encode(rememberedCardPositions) else {
            preferences.removeObject(forKey: "arrival-card-positions")
            return
        }
        preferences.set(data, forKey: "arrival-card-positions")
    }

    public func setDisplayDuration(_ text: String) throws {
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            Self.notificationRange.contains(value)
        else { throw NotificationSettingsError.invalidDuration }
        notificationSeconds = value
    }

    public func displayDuration(automaticallyCopied: Bool) -> TimeInterval {
        // An automatic copy does not shorten the card: clicking it can still fill the field.
        TimeInterval(notificationSeconds)
    }

    public func actionForCodeCard(writableTargetAvailable: Bool) -> CodeCardClickAction {
        cardClickAction == .fill && writableTargetAvailable ? .fill : .copy
    }
}

public enum CodeCardClickAction: String, CaseIterable, Equatable, Hashable, Sendable {
    case fill
    case copy
}

public enum NotificationSettingsError: LocalizedError {
    case invalidDuration
    public var errorDescription: String? { "请输入 5–300 之间的整数秒数。" }
}
