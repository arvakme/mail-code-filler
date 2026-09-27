import Foundation
import Testing

@testable import MailCodeCore

struct CandidateVaultTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func message(_ account: String = "gmail@example.test", validity: UInt32 = 1, uid: UInt32 = 1) -> MessageID
    {
        MessageID(account: account, mailbox: "INBOX", uidValidity: validity, uid: uid)
    }

    @Test func duplicateDoesNotRenewExpiryOrOverwriteCode() async throws {
        let vault = CandidateVault()
        await vault.insert(
            message: message(), codes: ["001234"], source: "Example", subject: "Your launch code",
            receivedAt: now, now: now)
        await vault.insert(
            message: message(), codes: ["999999"], source: "Other", subject: "Replacement",
            receivedAt: now, now: now + 30)
        let entries = await vault.snapshot(now: now + 30)
        #expect(entries.compactMap(\.code) == ["001234"])
        #expect(entries.first?.subject == "Your launch code")
        let id = try #require(entries.first?.id)
        #expect(await vault.candidate(id: id, now: now + CandidateVault.retention) == nil)
    }

    @Test func accountAndUIDValidityArePartOfIdentity() async {
        let vault = CandidateVault()
        for id in [message(), message("outlook@example.test"), message(validity: 2)] {
            await vault.insert(
                message: id, codes: ["001234"], source: "Example", receivedAt: now, now: now)
        }
        #expect(await vault.snapshot(now: now).count == 3)
        await vault.remove(account: "gmail@example.test")
        #expect(await vault.snapshot(now: now).map(\.id.message.account) == ["outlook@example.test"])
    }

    @Test func sameUIDInInboxAndJunkKeepDistinctSourceAndConsumption() async throws {
        let vault = CandidateVault()
        let inbox = message(uid: 12)
        let junk = MessageID(
            account: inbox.account, mailbox: "Junk Email", uidValidity: inbox.uidValidity, uid: inbox.uid)
        await vault.insert(
            message: inbox, codes: ["123456"], source: "Example", receivedAt: now, now: now)
        await vault.insert(
            message: junk, codes: ["654321"], source: "Example", receivedAt: now, now: now,
            isFromJunk: true)
        let candidates = await vault.snapshot(now: now)
        #expect(candidates.count == 2)
        let junkCandidate = try #require(candidates.first(where: { $0.id.message.mailbox == "Junk Email" }))
        #expect(junkCandidate.isFromJunk)
        #expect(candidates.first(where: { $0.id.message.mailbox == "INBOX" })?.isFromJunk == false)
        #expect(await vault.consume(id: junkCandidate.id, afterSuccessfulAction: true, now: now) != nil)
        #expect(await vault.snapshot(now: now).map(\.code) == ["123456"])
        #expect(await vault.snapshot(now: now + CandidateVault.retention).isEmpty)
    }

    @Test func staleOrFutureMessageCannotExtendRetention() async {
        let vault = CandidateVault()
        for date in [now - CandidateVault.retention, now + 1] {
            await vault.insert(
                message: message(), codes: ["001234"], source: "Example", receivedAt: date, now: now)
        }
        #expect(await vault.snapshot(now: now).isEmpty)
    }

    @Test func lateCodeMergesWithLinkAndNeitherRenewsTheMessageExpiry() async throws {
        let vault = CandidateVault()
        let message = message()
        let url = try #require(URL(string: "https://login.example.test/magic?token=secret"))
        let link = SignInLink(url: url)
        await vault.insert(
            message: message, codes: [], loginLink: link, source: "Example", subject: "Sign in",
            receivedAt: now, now: now)
        await vault.insert(
            message: message, codes: ["001234"], source: "Example", subject: "Sign in",
            receivedAt: now, now: now + 30)
        await vault.insert(
            message: message, codes: ["999999"], loginLink: link, source: "Duplicate",
            subject: "Changed", receivedAt: now, now: now + 40)

        let candidates = await vault.snapshot(now: now + 40)
        #expect(candidates.count == 2)
        #expect(candidates.compactMap(\.code) == ["001234"])
        #expect(candidates.compactMap(\.loginLink) == [link])
        #expect(candidates.allSatisfy { $0.expiresAt == now + CandidateVault.retention })
        #expect(await vault.snapshot(now: now + CandidateVault.retention).isEmpty)
    }

    @Test func consumeRemovesOnlyTheUsedCandidateAndFailureKeepsIt() async throws {
        let vault = CandidateVault()
        let message = message(uid: 20)
        let url = try #require(URL(string: "https://login.example.test/magic?token=secret"))
        await vault.insert(
            message: message, codes: ["001234"], loginLink: SignInLink(url: url),
            source: "Example", receivedAt: now, now: now)
        let initial = await vault.snapshot(now: now)
        let code = try #require(initial.first(where: { $0.isCode }))
        let link = try #require(initial.first(where: { $0.loginLink != nil }))

        #expect(await vault.consume(id: code.id, afterSuccessfulAction: false, now: now) == nil)
        #expect(await vault.snapshot(now: now) == initial)
        #expect(await vault.consume(id: code.id, afterSuccessfulAction: true, now: now) == code)
        #expect(await vault.snapshot(now: now) == [link])
    }

    @Test func backfillCannotResurrectConsumedCandidateUntilOriginalExpiry() async throws {
        let vault = CandidateVault()
        let message = message(uid: 21)
        await vault.insert(
            message: message, codes: ["001234"], source: "Example", receivedAt: now, now: now)
        let candidate = try #require(await vault.snapshot(now: now).first)
        var tracker = CandidateArrivalTracker(startedAt: now)
        #expect(tracker.receive([candidate], now: now)?.candidates == [candidate])
        #expect(await vault.consume(id: candidate.id, afterSuccessfulAction: true, now: now) == candidate)

        await vault.insert(
            message: message, codes: ["999999"], source: "Backfill", receivedAt: now, now: now + 30)
        #expect(await vault.snapshot(now: now + 30).isEmpty)
        #expect(tracker.receive(await vault.snapshot(now: now + 30), now: now + 30) == nil)
        #expect(await vault.snapshot(now: now + CandidateVault.retention).isEmpty)
    }

    @Test func lateJevCodeCanJoinAfterLinkWasConsumedWithoutAnotherCard() async throws {
        let vault = CandidateVault()
        let message = message(uid: 22)
        let url = try #require(URL(string: "https://login.example.test/magic?token=secret"))
        await vault.insert(
            message: message, codes: [], loginLink: SignInLink(url: url), source: "Example",
            subject: "Sign in", receivedAt: now, now: now)
        var tracker = CandidateArrivalTracker(startedAt: now)
        let link = try #require(await vault.snapshot(now: now).first)
        #expect(tracker.receive([link], now: now)?.candidates == [link])
        #expect(await vault.consume(id: link.id, afterSuccessfulAction: true, now: now) == link)

        await vault.insert(
            message: message, codes: ["001234"], source: "Example", subject: "Sign in",
            receivedAt: now, now: now + 1)
        let lateCode = try #require(await vault.snapshot(now: now + 1).first)
        #expect(lateCode.code == "001234")
        #expect(tracker.receive([lateCode], now: now + 1) == nil)
        await vault.insert(
            message: message, codes: [], loginLink: SignInLink(url: url), source: "Backfill",
            receivedAt: now, now: now + 2)
        #expect(await vault.snapshot(now: now + 2) == [lateCode])
    }

    @Test func newArrivalAndExpiryCannotRedirectSelection() async throws {
        let vault = CandidateVault()
        await vault.insert(
            message: message(), codes: ["001234"], source: "Example", receivedAt: now, now: now)
        let first = try #require(await vault.snapshot(now: now).first)
        var selection = CandidateSelection()
        selection.select(first.id)
        await vault.insert(
            message: message(uid: 2), codes: ["567890"], source: "Example", receivedAt: now + 1, now: now + 1)
        selection.reconcile(with: await vault.snapshot(now: now + 1))
        #expect(selection.id == first.id)
        selection.reconcile(with: await vault.snapshot(now: now + CandidateVault.retention))
        #expect(selection.id == nil)
    }
}
