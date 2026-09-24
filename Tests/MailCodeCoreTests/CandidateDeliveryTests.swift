import AppKit
import Testing

@testable import MailCodeCore

struct CandidateDeliveryTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func candidates(uid: UInt32 = 1, codes: [String] = ["001234"], age: TimeInterval = 0) async
        -> [Candidate]
    {
        let vault = CandidateVault()
        await vault.insert(
            message: .init(account: "test@example.test", mailbox: "INBOX", uidValidity: 1, uid: uid),
            codes: codes, source: "Synthetic", receivedAt: now + age, now: now + max(0, age))
        return await vault.snapshot(now: now + max(0, age))
    }

    @Test func startupHistoryAndReconnectDoNotTriggerAgain() async {
        var tracker = CandidateArrivalTracker(startedAt: now)
        let old = await candidates(age: -30)
        let new = await candidates(uid: 2, age: 1)
        #expect(tracker.receive(old, now: now) == nil)
        #expect(tracker.receive(new + old, now: now + 1)?.candidates == new)
        #expect(tracker.receive([], now: now + 2) == nil)
        #expect(tracker.receive(new, now: now + 3) == nil)
    }

    @Test func olderUnusedCodesDropOffTheCardOutsideTheBurstWindow() async {
        var tracker = CandidateArrivalTracker(startedAt: now)
        let first = await candidates(uid: 5, age: 1)
        #expect(tracker.receive(first, now: now + 1)?.candidates == first)
        let burst = await candidates(uid: 6, age: 60)
        #expect(tracker.receive(burst + first, now: now + 60)?.candidates == burst + first)
        let later = await candidates(uid: 7, age: 400)
        #expect(tracker.receive(later + burst + first, now: now + 400)?.candidates == later)
    }

    @Test func mailFromJustBeforeARestartStillGetsACard() async {
        var tracker = CandidateArrivalTracker(startedAt: now, launchGrace: 180)
        let restartGap = await candidates(uid: 3, age: -50)
        let older = await candidates(uid: 4, age: -400)
        #expect(tracker.receive(restartGap + older, now: now)?.candidates == restartGap)
        #expect(tracker.receive(restartGap + older, now: now + 1) == nil)
    }

    @Test func lateOlderMailJoinsTheStackBelowNewestAndExpiredMailIsDropped() async {
        var tracker = CandidateArrivalTracker(startedAt: now)
        let newest = await candidates(uid: 3, age: 3)
        let late = await candidates(uid: 2, age: 2)
        #expect(tracker.receive(newest, now: now + 3)?.candidates == newest)
        #expect(tracker.receive(late + newest, now: now + 4)?.candidates == newest + late)
        let expiring = await candidates(uid: 4, age: 4)
        #expect(tracker.receive(expiring, now: now + CandidateVault.retention + 4) == nil)
    }

    @Test func ambiguousMailKeepsAllChoicesTogether() async {
        var tracker = CandidateArrivalTracker(startedAt: now)
        let ambiguous = await candidates(codes: ["001234", "aB12cD"])
        let arrival = tracker.receive(ambiguous, now: now, automaticCopyEnabled: true)
        #expect(arrival?.candidates.compactMap(\.code) == ["001234", "aB12cD"])
        #expect(arrival?.automaticCopy == nil)
        #expect(tracker.receive(ambiguous, now: now + 1) == nil)
    }

    @Test func enablingAutomaticCopyOnlyAffectsFutureArrivals() async {
        var tracker = CandidateArrivalTracker(startedAt: now)
        let first = await candidates()
        let manual = tracker.receive(first, now: now)
        #expect(manual?.candidates == first)
        #expect(manual?.automaticCopy == nil)
        #expect(tracker.receive(first, now: now + 1, automaticCopyEnabled: true) == nil)
        let next = await candidates(uid: 2, age: 2)
        let automatic = tracker.receive(next + first, now: now + 2, automaticCopyEnabled: true)
        #expect(automatic?.automaticCopy == next.first)
    }

    @Test func lateCodeEnrichesListButOnlyPromptsIfMessageHasNotBeenPrompted() async throws {
        let message = MessageID(account: "test@example.test", mailbox: "INBOX", uidValidity: 1, uid: 90)
        let url = try #require(URL(string: "https://login.example.test/magic?token=secret"))
        let vault = CandidateVault()
        await vault.insert(
            message: message, codes: [], loginLink: SignInLink(url: url), source: "Example",
            subject: "Sign in", receivedAt: now, now: now)
        var tracker = CandidateArrivalTracker(startedAt: now)
        let linkOnly = await vault.snapshot(now: now)
        let first = tracker.receive(linkOnly, now: now, automaticCopyEnabled: true)
        #expect(first?.candidates.count == 1)
        #expect(first?.automaticCopy == nil)

        await vault.insert(
            message: message, codes: ["001234"], source: "Example", subject: "Sign in",
            receivedAt: now, now: now + 1)
        let combined = await vault.snapshot(now: now + 1)
        let second = tracker.receive(combined, now: now + 1, automaticCopyEnabled: true)
        #expect(second?.automaticCopy == nil)
        #expect(second == nil)

        // If both candidates are merged before the first prompt, one card contains both.
        var firstPromptTracker = CandidateArrivalTracker(startedAt: now)
        let initial = firstPromptTracker.receive(combined, now: now + 1, automaticCopyEnabled: true)
        #expect(initial?.candidates.count == 2)
        #expect(initial?.candidates.contains { $0.loginLink != nil } == true)
        #expect(initial?.candidates.compactMap(\.code) == ["001234"])
        #expect(initial?.automaticCopy == nil)
    }

    @Test func quietPeriodKeepsCandidatesVisibleAndDoesNotReplayOrAutoCopy() async {
        let vault = CandidateVault()
        let message = MessageID(account: "test@example.test", mailbox: "INBOX", uidValidity: 1, uid: 91)
        await vault.insert(
            message: message, codes: ["001234"], source: "Synthetic", receivedAt: now + 30,
            now: now + 30)
        let candidate = await vault.snapshot(now: now + 30).first!
        let period = DoNotDisturbPeriod(
            choice: .oneHour, startedAt: now, endsAt: now + 60)
        var tracker = CandidateArrivalTracker(startedAt: now)

        #expect(
            tracker.receive(
                [candidate], now: now + 30, automaticCopyEnabled: true, quietPeriod: period) == nil)
        #expect(await vault.snapshot(now: now + 30) == [candidate])
        #expect(
            tracker.receive(
                [candidate], now: now + 61, automaticCopyEnabled: true, quietPeriod: period) == nil)
        #expect(await vault.snapshot(now: now + 61) == [candidate])
    }

    @Test func automaticCopyLeavesCandidateUntilUserConsumesIt() async throws {
        let vault = CandidateVault()
        let message = MessageID(account: "test@example.test", mailbox: "INBOX", uidValidity: 1, uid: 92)
        await vault.insert(
            message: message, codes: ["001234"], source: "Synthetic", receivedAt: now, now: now)
        let candidate = try #require(await vault.snapshot(now: now).first)
        var tracker = CandidateArrivalTracker(startedAt: now)

        #expect(
            tracker.receive([candidate], now: now, automaticCopyEnabled: true)?.automaticCopy == candidate)
        #expect(await vault.snapshot(now: now) == [candidate])
        #expect(
            await vault.consume(
                id: candidate.id, afterSuccessfulAction: true, now: now) == candidate)
        #expect(await vault.snapshot(now: now).isEmpty)
    }

    @Test func stackIsNewestFirstAndContainsAtMostFiveVisibleRowsPlusOverflow() async {
        var tracker = CandidateArrivalTracker(startedAt: now)
        var all: [Candidate] = []
        for uid in UInt32(1)...UInt32(7) {
            all += await candidates(uid: uid, age: TimeInterval(uid))
        }
        let arrival = tracker.receive(all, now: now + 7)
        #expect(
            arrival?.candidates.compactMap(\.code) == [
                "001234", "001234", "001234", "001234", "001234", "001234", "001234",
            ])
        #expect(arrival?.candidates.map(\.id.message.uid) == [7, 6, 5, 4, 3, 2, 1])
        #expect(max(0, (arrival?.candidates.count ?? 0) - 5) == 2)
    }

    @Test func consumingARowRemovesItFromThePendingStack() async throws {
        var tracker = CandidateArrivalTracker(startedAt: now)
        let first = try #require(await candidates(uid: 1).first)
        let second = try #require(await candidates(uid: 2, age: 1).first)
        _ = tracker.receive([first, second], now: now + 1)
        let vault = CandidateVault()
        await vault.insert(
            message: first.id.message, codes: [first.code!], source: first.source,
            receivedAt: first.receivedAt, now: now)
        await vault.insert(
            message: second.id.message, codes: [second.code!], source: second.source,
            receivedAt: second.receivedAt, now: now + 1)
        _ = await vault.consume(id: first.id, afterSuccessfulAction: true, now: now)
        let remaining = await vault.snapshot(now: now + 1)
        #expect(tracker.pendingCandidates(in: remaining, now: now + 1) == [second])
    }

    @Test func prelaunchCandidatesStayListOnlyAndDoNotEnterTheStackLater() async {
        var tracker = CandidateArrivalTracker(startedAt: now)
        let old = await candidates(uid: 1, age: -1)
        #expect(tracker.receive(old, now: now) == nil)
        let fresh = await candidates(uid: 2, age: 1)
        #expect(tracker.receive(old + fresh, now: now + 1)?.candidates == fresh)
    }

    @Test @MainActor func clipboardPreservesCodeAndRejectsExpiredWithoutOverwriting() async throws {
        let board = NSPasteboard(name: .init("mail-code-test-\(UUID())"))
        defer { board.releaseGlobally() }
        let clipboard = CandidateClipboard(pasteboard: board)
        let numeric = try #require(await candidates().first)
        try clipboard.copy(numeric, now: now)
        #expect(board.string(forType: .string) == "001234")
        let mixed = try #require(await candidates(uid: 2, codes: ["aB12cD"]).first)
        try clipboard.copy(mixed, now: now)
        #expect(board.string(forType: .string) == "aB12cD")
        #expect(throws: CandidateCopyError.self) {
            try clipboard.copy(numeric, now: now + CandidateVault.retention)
        }
        #expect(board.string(forType: .string) == "aB12cD")
    }
}
