import Foundation
import Testing

@testable import MailCodeCore

struct SiteCandidateRankerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func candidate(
        uid: UInt32, sender: String, kind: CandidateKind = .code("123456"),
        age: TimeInterval = 0, lifetime: TimeInterval = 600
    ) -> Candidate {
        let date = now.addingTimeInterval(-age)
        return Candidate(
            id: .init(message: .init(account: "test", mailbox: "INBOX", uidValidity: 1, uid: uid), index: 0),
            kind: kind, source: sender, subject: "", receivedAt: date,
            expiresAt: date.addingTimeInterval(lifetime))
    }

    @Test func exactMatchRanksAheadOfNewerCandidate() {
        let ranker = CurrentSiteCandidateRanker(aliasGroups: [])
        let page = ActivePage(
            registrableDomain: "example.co.uk", host: "login.example.co.uk", looksLikeAuthPage: true)
        let olderMatch = candidate(uid: 1, sender: "A <code@mail.example.co.uk>", age: 30)
        let newerOther = candidate(uid: 2, sender: "B <code@other.test>")
        let ranked = ranker.rank([newerOther, olderMatch], for: page)
        #expect(ranked.map(\.id) == [olderMatch.id, newerOther.id])
        #expect(ranked.map(\.matchesCurrentSite) == [true, false])
        #expect(ranker.bestCode(in: [newerOther, olderMatch], for: page, now: now)?.id == olderMatch.id)
    }

    @Test func aliasesAreExplicitAndMailboxProvidersNeverMatch() {
        let ranker = CurrentSiteCandidateRanker(aliasGroups: [["openai.com", "chatgpt.com"]])
        let page = ActivePage(registrableDomain: "chatgpt.com", host: "chatgpt.com", looksLikeAuthPage: false)
        let alias = candidate(uid: 1, sender: "OpenAI <no-reply@openai.com>")
        let personal = candidate(uid: 2, sender: "User <person@gmail.com>")
        #expect(ranker.matches(alias, page: page))
        #expect(
            !ranker.matches(
                personal,
                page: ActivePage(
                    registrableDomain: "gmail.com", host: "gmail.com", looksLikeAuthPage: false)))
    }

    @Test func bestIgnoresLinksAndExpiredCodes() throws {
        let ranker = CurrentSiteCandidateRanker(aliasGroups: [])
        let url = try #require(URL(string: "https://example.com/login"))
        let link = candidate(
            uid: 1, sender: "A <code@example.com>",
            kind: .loginLink(
                SignInLink(url: url)))
        let expired = candidate(uid: 2, sender: "B <code@example.com>", age: 700)
        let fresh = candidate(uid: 3, sender: "C <code@other.test>", age: 10)
        #expect(ranker.bestCode(in: [link, expired, fresh], for: nil, now: now)?.id == fresh.id)
    }

    @Test func tiesUseStableIDOrder() {
        let ranker = CurrentSiteCandidateRanker(aliasGroups: [])
        let first = candidate(uid: 1, sender: "A <code@example.com>")
        let second = candidate(uid: 2, sender: "B <code@example.com>")
        #expect(ranker.rank([second, first], for: nil).map(\.id) == [first.id, second.id])
    }
}
