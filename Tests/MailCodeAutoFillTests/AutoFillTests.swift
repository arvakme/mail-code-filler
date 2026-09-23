import Foundation
import MailCodeCore
import Synchronization
import Testing

@testable import MailCodeAutoFill

struct AutoFillTests {
    let now = Date()

    func candidate(uid: UInt32 = 1, account: String = "user@example.test", at date: Date? = nil) async throws
        -> Candidate
    {
        let vault = CandidateVault()
        let date = date ?? now
        await vault.insert(
            message: .init(account: account, mailbox: "INBOX", uidValidity: 1, uid: uid),
            codes: [uid == 1 ? "001234" : "987654"], source: "login@example.test", receivedAt: date, now: date
        )
        return try #require(await vault.snapshot(now: date).first)
    }

    @Test func unassociatedMailNeverInventsWebsiteIdentity() async throws {
        let mail = try await candidate()
        let otherAccount = try AutoFillRule(
            account: "other@example.test", sender: mail.source, domain: "example.test")
        let snapshot = AutoFillSnapshot(candidates: [mail], rules: [otherAccount], now: now)
        let entry = try #require(snapshot.entries.first)
        #expect(entry.domains.isEmpty)
        #expect(entry.id.count == 64)
        let code = try #require(mail.code)
        #expect(!entry.id.contains(code))
        let rule = try AutoFillRule(
            account: mail.id.message.account, sender: mail.source, domain: " Accounts.Example.test ")
        let mapped = AutoFillSnapshot(candidates: [mail], rules: [rule], now: now)
        #expect(mapped.entries.first?.domains == ["accounts.example.test"])
        #expect(mapped.entries.first?.id == entry.id)
    }

    @Test func loginLinkCandidateIsExcludedFromAutoFillProjection() async throws {
        let vault = CandidateVault()
        let date = now
        let linkURL = try #require(URL(string: "https://login.example.test/magic?token=bearer"))
        await vault.insert(
            message: .init(account: "user@example.test", mailbox: "INBOX", uidValidity: 1, uid: 12),
            codes: ["001234"], loginLink: SignInLink(url: linkURL), source: "login@example.test",
            subject: "Sign in", receivedAt: date, now: date)

        let candidates = await vault.snapshot(now: date)
        let snapshot = AutoFillSnapshot(candidates: candidates, rules: [], now: date)
        #expect(candidates.count == 2)
        #expect(snapshot.entries.count == 1)
        #expect(snapshot.entries.first?.code == "001234")
        #expect(snapshot.entries.allSatisfy { !$0.id.contains("bearer") })
    }

    @Test(arguments: [
        "https://example.test", "example.test/path", "*.example.test", "example.test@evil.test",
        "a..test", "-a.test", "a-.test", "127.0.0.1", "example.test\n.evil.test", "",
    ])
    func invalidDomainsAreNotSuggestions(_ input: String) {
        #expect(throws: AutoFillError.invalidDomain) { try AutoFillRule.normalizedDomain(input) }
    }

    @Test func readerRechecksPersistentExpiryAndExactIdentityOnEveryFill() async throws {
        let first = try await candidate()
        let second = try await candidate(uid: 2, at: now + 1)
        let store = MemoryAutoFillStore()
        let rule = try AutoFillRule(
            account: first.id.message.account, sender: first.source, domain: "example.test")
        let snapshot = AutoFillSnapshot(candidates: [first, second], rules: [rule], now: now + 1)
        try store.saveSnapshot(snapshot)
        let restored = try JSONDecoder().decode(AutoFillSnapshot.self, from: JSONEncoder().encode(snapshot))
        let id = try #require(restored.entries.first?.id)
        let reader = AutoFillReader(store: store)
        #expect(try reader.resolve(id: id, domain: "evil.test", at: now + 1) == nil)
        #expect(try reader.resolve(id: id, domain: "example.test", at: now + 1)?.code == "001234")
        #expect(try reader.resolve(id: id, at: now + CandidateVault.retention) == nil)
        #expect(
            try reader.entries(at: now + CandidateVault.retention, preferredDomains: []).map(\.code) == [
                "987654"
            ])
        try store.saveSnapshot(AutoFillSnapshot(candidates: [], rules: [], now: now))
        #expect(try reader.resolve(id: id, at: now + 1) == nil)
    }

    @Test @MainActor func systemIndexContainsNoCodesAndRanksNewestMailFirst() async throws {
        let first = try await candidate()
        let second = try await candidate(uid: 2, at: now + 1)
        let rule = try AutoFillRule(
            account: first.id.message.account, sender: first.source, domain: "example.test")
        let snapshot = AutoFillSnapshot(candidates: [first, second], rules: [rule], now: now + 1)
        let identities = SystemAutoFillIndex.identities(for: snapshot, at: now + 1)
        #expect(identities.count == 2)
        #expect(identities.map(\.serviceIdentifier.identifier) == ["example.test", "example.test"])
        #expect(identities.map(\.recordIdentifier) == snapshot.entries.map(\.id))
        let firstCode = try #require(first.code)
        let secondCode = try #require(second.code)
        #expect(identities.allSatisfy { !$0.label.contains(firstCode) && !$0.label.contains(secondCode) })
        #expect(identities[1].rank > identities[0].rank)
        #expect(SystemAutoFillIndex.identities(for: snapshot, at: now + CandidateVault.retention + 1).isEmpty)
    }

    @Test @MainActor func publishesOnlyAfterKeychainWriteAndReportsDisabledProvider() async throws {
        let store = MemoryAutoFillStore()
        let index = TestIdentityIndex()
        index.enabled = false
        let publisher = AutoFillPublisher(store: store, index: index)
        try publisher.replaceCandidates([try await candidate()])
        await publisher.settle()
        #expect(try store.loadSnapshot()?.entries.count == 1)
        #expect(publisher.state == .disabled)
        #expect(index.snapshots.isEmpty)
        index.enabled = true
        store.setWriteError(.keychain(-34018))
        #expect(throws: AutoFillError.keychain(-34018)) {
            try publisher.replaceCandidates([])
        }
        await publisher.settle()
        #expect(index.snapshots.isEmpty)
        #expect(publisher.state == .failed(AutoFillError.keychain(-34018).localizedDescription))
    }

    @Test @MainActor func slowIdentityUpdateCannotResurrectClearedCodes() async throws {
        let store = MemoryAutoFillStore()
        let index = TestIdentityIndex()
        index.blockFirst = true
        let publisher = AutoFillPublisher(store: store, index: index)
        try publisher.replaceCandidates([try await candidate()])
        await index.waitUntilBlocked()
        let firstID = try #require(store.loadSnapshot()?.entries.first?.id)
        try publisher.replaceCandidates([])
        #expect(try AutoFillReader(store: store).resolve(id: firstID, at: now) == nil)
        #expect(index.snapshots.count == 1)
        index.release()
        await publisher.settle()
        #expect(index.snapshots.count == 2)
        #expect(index.snapshots.last?.entries.isEmpty == true)
        #expect(publisher.state == .ready(suggestions: 0))
    }

    @Test(arguments: [false, true]) @MainActor
    func pendingEnabledCheckSkipsWithdrawnPublication(replaceAccount: Bool) async throws {
        let store = MemoryAutoFillStore()
        let index = TestIdentityIndex()
        index.blockEnabled = true
        let publisher = AutoFillPublisher(store: store, index: index)
        try publisher.replaceCandidates([try await candidate()])
        await index.waitUntilBlocked()
        let oldID = try #require(store.loadSnapshot()?.entries.first?.id)
        let replacement = try await candidate(account: "other@example.test")
        try publisher.replaceCandidates(replaceAccount ? [replacement] : [])
        index.release()
        await publisher.settle()
        #expect(index.snapshots.count == 1)
        let expectedAccounts = replaceAccount ? ["other@example.test"] : []
        #expect(index.snapshots.first?.entries.map(\.account) == expectedAccounts)
        #expect(try AutoFillReader(store: store).resolve(id: oldID, at: now) == nil)
        #expect(publisher.state == .ready(suggestions: 0))
    }

    @Test @MainActor func failedWithdrawalInvalidatesPendingEnabledCheck() async throws {
        let store = MemoryAutoFillStore()
        let index = TestIdentityIndex()
        index.blockEnabled = true
        let publisher = AutoFillPublisher(store: store, index: index)
        try publisher.replaceCandidates([try await candidate()])
        await index.waitUntilBlocked()
        let oldID = try #require(store.loadSnapshot()?.entries.first?.id)
        store.setWriteError(.keychain(-25308))
        #expect(throws: AutoFillError.keychain(-25308)) {
            try publisher.replaceCandidates([])
        }
        index.release()
        await publisher.settle()
        #expect(index.snapshots.isEmpty)
        #expect(publisher.state == .failed(AutoFillError.keychain(-25308).localizedDescription))
        // A failed Keychain write cannot promise revocation of the old persisted data.
        let reader = AutoFillReader(store: store)
        #expect(try reader.resolve(id: oldID, at: now) != nil)
        store.setWriteError(nil)
        try publisher.replaceCandidates([])
        await publisher.settle()
        #expect(try store.loadSnapshot()?.entries.isEmpty == true)
        #expect(try reader.resolve(id: oldID, at: now) == nil)
        #expect(index.snapshots.count == 1)
        #expect(index.snapshots.last?.entries.isEmpty == true)
        #expect(publisher.state == .ready(suggestions: 0))
    }

    @Test @MainActor func ruleRemovalReportsProjectionWriteFailureToCaller() async throws {
        let mail = try await candidate()
        let store = MemoryAutoFillStore()
        let index = TestIdentityIndex()
        let publisher = AutoFillPublisher(store: store, index: index)
        try publisher.replaceCandidates([mail])
        try publisher.addRule(for: mail, domain: "example.test")
        await publisher.settle()
        let rule = try #require(publisher.rules.first)
        store.setWriteError(.keychain(-25308))
        #expect(throws: AutoFillError.keychain(-25308)) {
            try publisher.removeRule(id: rule.id)
        }
        await publisher.settle()
        #expect(publisher.state == .failed(AutoFillError.keychain(-25308).localizedDescription))
        #expect(try store.loadRules().isEmpty)
        #expect(try store.loadSnapshot()?.entries.first?.domains == ["example.test"])
        store.setWriteError(nil)
        try publisher.replaceCandidates([mail])
        await publisher.settle()
        let id = try #require(store.loadSnapshot()?.entries.first?.id)
        #expect(try AutoFillReader(store: store).resolve(id: id, domain: "example.test", at: now) == nil)
        #expect(publisher.state == .ready(suggestions: 0))
    }

    @Test @MainActor func duplicateRuleRetriesFailedProjectionWrite() async throws {
        let mail = try await candidate()
        let store = MemoryAutoFillStore()
        let index = TestIdentityIndex()
        let publisher = AutoFillPublisher(store: store, index: index)
        try publisher.replaceCandidates([mail])
        await publisher.settle()
        store.setWriteError(.keychain(-25308))
        #expect(throws: AutoFillError.keychain(-25308)) {
            try publisher.addRule(for: mail, domain: "example.test")
        }
        let savedRule = try #require(publisher.rules.first)
        #expect(try store.loadRules() == [savedRule])
        #expect(try store.loadSnapshot()?.entries.first?.domains.isEmpty == true)
        // Repeating while still locked must keep reporting failure, not early-return success.
        #expect(throws: AutoFillError.keychain(-25308)) {
            try publisher.addRule(for: mail, domain: "example.test")
        }
        store.setWriteError(nil)
        try publisher.addRule(for: mail, domain: "example.test")
        await publisher.settle()
        #expect(publisher.rules == [savedRule])
        #expect(try store.loadSnapshot()?.entries.first?.domains == ["example.test"])
        #expect(index.snapshots.last?.entries.first?.domains == ["example.test"])
        #expect(publisher.state == .ready(suggestions: 1))
    }

    @Test @MainActor func identityFailureIsVisibleAndRuleRemovalWithdrawsSuggestions() async throws {
        let mail = try await candidate()
        let store = MemoryAutoFillStore()
        let index = TestIdentityIndex()
        let publisher = AutoFillPublisher(store: store, index: index)
        try publisher.replaceCandidates([mail])
        try publisher.addRule(for: mail, domain: "example.test")
        await publisher.settle()
        #expect(publisher.state == .ready(suggestions: 1))
        index.fail = true
        try publisher.removeRules(account: mail.id.message.account)
        await publisher.settle()
        #expect(try store.loadSnapshot()?.entries.first?.domains.isEmpty == true)
        #expect(try store.loadRules().isEmpty)
        #expect(publisher.state == .failed(AutoFillError.identityUpdate.localizedDescription))
        index.fail = false
        try publisher.replaceCandidates([mail])
        await publisher.settle()
        #expect(publisher.state == .ready(suggestions: 0))
    }
}

final class MemoryAutoFillStore: AutoFillStore {
    struct State {
        var snapshot: AutoFillSnapshot?
        var rules: [AutoFillRule] = []
        var writeError: AutoFillError?
    }
    private let state = Mutex(State())
    func loadSnapshot() throws -> AutoFillSnapshot? { state.withLock { $0.snapshot } }
    func loadRules() throws -> [AutoFillRule] { state.withLock { $0.rules } }
    func saveSnapshot(_ snapshot: AutoFillSnapshot) throws {
        try state.withLock {
            if let error = $0.writeError { throw error }
            $0.snapshot = snapshot
        }
    }
    func saveRules(_ rules: [AutoFillRule]) throws { state.withLock { $0.rules = rules } }
    func setWriteError(_ error: AutoFillError?) { state.withLock { $0.writeError = error } }
}

@MainActor
final class TestIdentityIndex: AutoFillIdentityIndex {
    var enabled = true
    var fail = false
    var blockFirst = false
    var blockEnabled = false
    var snapshots: [AutoFillSnapshot] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?

    func isEnabled() async -> Bool {
        if blockEnabled {
            blockEnabled = false
            await withCheckedContinuation {
                gate = $0
                entered?.resume()
                entered = nil
            }
        }
        return enabled
    }
    func replace(with snapshot: AutoFillSnapshot) async throws {
        snapshots.append(snapshot)
        if blockFirst, snapshots.count == 1 {
            await withCheckedContinuation {
                gate = $0
                entered?.resume()
                entered = nil
            }
        }
        if fail { throw AutoFillError.identityUpdate }
    }
    func waitUntilBlocked() async {
        if gate != nil { return }
        await withCheckedContinuation { entered = $0 }
    }
    func release() {
        gate?.resume()
        gate = nil
    }
}
