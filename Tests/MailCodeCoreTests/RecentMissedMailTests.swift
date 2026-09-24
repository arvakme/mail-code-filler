import Foundation
import Testing

@testable import MailCodeCore

struct RecentMissedMailTests {
    @Test func boundedDeduplicatedAndAccountRemoval() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ring = RecentMissedMailRing(limit: 2, now: { now })
        for uid: UInt32 in 1...3 {
            await ring.record(mail(uid: uid, account: uid == 3 ? "other" : "one", receivedAt: now))
        }
        #expect(await ring.snapshot().map(\.id.uid) == [3, 2])
        await ring.record(mail(uid: 2, account: "one", receivedAt: now))
        #expect(await ring.snapshot().map(\.id.uid) == [2, 3])
        await ring.remove(accountID: "one")
        let remaining = await ring.snapshot()
        #expect(remaining.count == 1)
        #expect(remaining[0].senderDomain == "example.test")
        await ring.clear()
        #expect(await ring.snapshot().isEmpty)
    }

    @Test func expiresAfterOneDay() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ring = RecentMissedMailRing(now: { now })
        await ring.record(mail(uid: 1, account: "one", receivedAt: now.addingTimeInterval(-86400)))
        #expect(await ring.snapshot().isEmpty)
    }

    private func mail(uid: UInt32, account: String, receivedAt: Date) -> ReceivedMail {
        ReceivedMail(
            id: MessageID(account: account, mailbox: "INBOX", uidValidity: 1, uid: uid),
            subject: "Example", bodies: ["private body"], sender: "Name <a@example.test>",
            receivedAt: receivedAt)
    }
}
