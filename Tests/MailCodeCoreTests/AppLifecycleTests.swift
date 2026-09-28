import Foundation
import Testing

@testable import MailCodeCore

struct AppLifecycleTests {
    @Test func firstLaunchCrashRecoveryAndCleanQuitHaveDistinctMarkers() {
        let suite = "MailCodeFillerTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let lifecycle = AppLifecycle(preferences: preferences)

        #expect(!lifecycle.beginLaunch())
        #expect(preferences.object(forKey: AppLifecycle.cleanShutdownKey) as? Bool == false)
        // No termination callback follows a crash or a cancelled quit.
        #expect(lifecycle.beginLaunch())
        lifecycle.recordCleanShutdown()
        #expect(!lifecycle.beginLaunch())
        #expect(lifecycle.beginLaunch())
    }

    @Test func intentionalHandoffDoesNotReportARecoveryButNextCrashDoes() {
        let suite = "MailCodeFillerTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let lifecycle = AppLifecycle(preferences: preferences)

        #expect(!lifecycle.beginLaunch())
        lifecycle.prepareHandoff(processID: 42, destination: .manual)
        #expect(!lifecycle.beginLaunch(afterHandoff: true))
        #expect(lifecycle.handoff == nil)
        #expect(lifecycle.beginLaunch())
    }

    @Test func duplicateRequiresMatchingUnexpiredHandoffAndNoThirdInstance() {
        let now = Date(timeIntervalSince1970: 1000)
        let handoff = AppHandoff(processID: 42, destination: .agent, at: now)
        let scenarios: [(pids: [Int32], mode: AppLaunchMode, date: Date, expected: AppLaunchDecision)] = [
            ([], .manual, now, .start),
            ([77], .manual, now, .start),
            ([42, 77], .agent, now, .waitForProcess(42)),
            ([42], .manual, now, .exit),
            ([42], .agent, now.addingTimeInterval(10), .exit),
            ([43], .agent, now, .exit),
            ([42, 43], .agent, now, .exit),
            ([42], .agent, now.addingTimeInterval(-1), .exit),
        ]
        for scenario in scenarios {
            #expect(
                AppLaunchDecision.decide(
                    processID: 77, runningProcessIDs: scenario.pids, mode: scenario.mode,
                    handoff: handoff, at: scenario.date) == scenario.expected)
        }
        #expect(
            AppLaunchDecision.decide(
                processID: 77, runningProcessIDs: [42], mode: .agent,
                handoff: nil, at: now) == .exit)
        #expect(!handoff.isValid(for: .agent, currentProcessID: 42, at: now))
    }

    @Test func handoffIsPersistedAcrossInstancesAndOnlyItsOwnerCanCancel() {
        let suite = "MailCodeFillerTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let old = AppLifecycle(preferences: preferences)
        let new = AppLifecycle(preferences: UserDefaults(suiteName: suite)!)
        let now = Date(timeIntervalSince1970: 1000)

        old.prepareHandoff(processID: 42, destination: .agent, at: now)
        #expect(new.handoff?.processID == 42)
        #expect(new.handoff?.expiresAt == Date(timeIntervalSince1970: 1010))
        #expect(new.handoff?.destination == .agent)
        new.cancelHandoff(processID: 43)
        #expect(new.handoff?.processID == 42)
        old.cancelHandoff(processID: 42)
        #expect(new.handoff == nil)
    }
}
