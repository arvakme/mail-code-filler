import Foundation

public enum DoNotDisturbChoice: String, CaseIterable, Equatable, Sendable {
    case thirtyMinutes
    case oneHour
    case tomorrowMorning
    case untilResumed
}

/// A persisted quiet interval shared by settings, arrival rules, and the App timer.
public struct DoNotDisturbPeriod: Equatable, Sendable {
    public let choice: DoNotDisturbChoice
    public let startedAt: Date
    public let endsAt: Date?

    public init(choice: DoNotDisturbChoice, startedAt: Date, endsAt: Date?) {
        self.choice = choice
        self.startedAt = startedAt
        self.endsAt = endsAt
    }

    public static func starting(
        _ choice: DoNotDisturbChoice, at now: Date, calendar: Calendar = .current
    ) -> DoNotDisturbPeriod {
        let end: Date?
        switch choice {
        case .thirtyMinutes:
            end = now.addingTimeInterval(30 * 60)
        case .oneHour:
            end = now.addingTimeInterval(60 * 60)
        case .tomorrowMorning:
            let nextDay = calendar.date(
                byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            end = nextDay.flatMap {
                calendar.date(
                    bySettingHour: 8, minute: 0, second: 0, of: $0,
                    matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
            }
        case .untilResumed:
            end = nil
        }
        return DoNotDisturbPeriod(choice: choice, startedAt: now, endsAt: end)
    }

    public func isActive(at now: Date) -> Bool {
        guard now >= startedAt else { return false }
        return endsAt.map { $0 > now } ?? (choice == .untilResumed)
    }

    public func contains(arrivalAt date: Date) -> Bool {
        guard date >= startedAt else { return false }
        return endsAt.map { date < $0 } ?? (choice == .untilResumed)
    }

    public func ending(at date: Date) -> DoNotDisturbPeriod {
        DoNotDisturbPeriod(choice: choice, startedAt: startedAt, endsAt: date)
    }

    public func recalculated(using calendar: Calendar) -> DoNotDisturbPeriod {
        guard choice == .tomorrowMorning else { return self }
        return Self.starting(choice, at: startedAt, calendar: calendar)
    }
}
