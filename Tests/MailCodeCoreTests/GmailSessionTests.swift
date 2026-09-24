import Foundation
import Testing

@testable import MailCodeCore

@Suite(.timeLimit(.minutes(1))) @MainActor
struct GmailSessionTests {
    @Test func receivedMailPauseAndRemovalRespectSessionBoundary() async throws {
        let store = MemoryGmailCredentials()
        let feed = ControlledGmailFeed()
        let vault = CandidateVault()
        let account = IMAPAccount(provider: .gmail, email: "person@gmail.com")
        let name = "MailCodeFiller.tests.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let session = GmailSession(
            account: account, vault: vault, feed: feed, credentials: store, preferences: preferences)
        var starts = feed.starts.makeAsyncIterator()
        try session.connect(email: "person@gmail.com", appPassword: "abcd efgh ijkl mnop")
        #expect(await starts.next() == "person@gmail.com")
        await feed.emit(.notice("部分邮件超过正文大小限制，未进行解析。"))
        await feed.emit(.state(.listening))
        #expect(session.notice == "部分邮件超过正文大小限制，未进行解析。")
        #expect(session.phase == .active(.listening))
        #expect(session.lastSynchronizedAt != nil)
        let mail = ReceivedMail(
            id: .init(account: "person@gmail.com", mailbox: "INBOX", uidValidity: 1, uid: 4),
            subject: "Sign in",
            bodies: ["Open the HTML version.\n--\nSignature", "Your verification code is 001234"],
            sender: "Example",
            receivedAt: Date()
        )
        await feed.emit(.message(mail))
        await feed.emit(.message(mail))
        #expect(await vault.snapshot(now: Date()).compactMap(\.code) == ["001234"])
        #expect(await vault.snapshot(now: Date()).first?.subject == "Sign in")
        await session.pause()
        #expect(session.phase == .paused)
        #expect(session.notice == nil)
        #expect(await vault.snapshot(now: Date()).isEmpty)
        await feed.emit(.message(mail))
        #expect(await vault.snapshot(now: Date()).isEmpty)
        let restored = GmailSession(
            account: account, vault: vault, feed: feed, credentials: store, preferences: preferences)
        restored.restore()
        #expect(restored.phase == .paused)
        session.resume()
        #expect(await starts.next() == "person@gmail.com")
        try await session.removeAccount()
        #expect(session.phase == .notConfigured)
        #expect(session.email == "person@gmail.com")
        #expect(try store.load(accountID: account.id) == nil)
    }

    @Test func updatingCredentialsCancelsOldFeedBeforeAcceptingNewMail() async throws {
        let store = MemoryGmailCredentials()
        let feed = ControlledGmailFeed()
        let vault = CandidateVault()
        let account = IMAPAccount(provider: .gmail, email: "person@gmail.com")
        let name = "MailCodeFiller.tests.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let session = GmailSession(
            account: account, vault: vault, feed: feed, credentials: store, preferences: preferences)
        var starts = feed.starts.makeAsyncIterator()
        try session.connect(email: "person@gmail.com", appPassword: "abcdefghijklmnop")
        #expect(await starts.next() == "person@gmail.com")
        let oldCallback = await feed.callback
        try session.connect(email: "person@gmail.com", appPassword: "ponmlkjihgfedcba")
        #expect(await starts.next() == "person@gmail.com")
        await oldCallback?(.state(.reconnecting))
        #expect(session.phase == .active(.connecting))
        await feed.emit(.state(.listening))
        #expect(session.email == "person@gmail.com")
        #expect(session.phase == .active(.listening))
        await session.pause()
        #expect(await feed.maximumConcurrentRuns == 1)
    }

    @Test func wakeReplacesActiveConnectionButDoesNotResumePausedAccount() async throws {
        let store = MemoryGmailCredentials()
        let feed = ControlledGmailFeed()
        let account = IMAPAccount(provider: .gmail, email: "person@gmail.com")
        let name = "MailCodeFiller.tests.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let session = GmailSession(
            account: account, vault: CandidateVault(), feed: feed, credentials: store,
            preferences: preferences)
        var starts = feed.starts.makeAsyncIterator()
        try session.connect(email: "person@gmail.com", appPassword: "abcdefghijklmnop")
        #expect(await starts.next() == "person@gmail.com")
        await feed.emit(.state(.listening))
        let lastLivenessCheck = try #require(session.lastSynchronizedAt)
        session.reconnectAfterWake()
        #expect(await starts.next() == "person@gmail.com")
        #expect(session.phase == .active(.connecting))
        #expect(session.lastSynchronizedAt == lastLivenessCheck)
        #expect(await feed.maximumConcurrentRuns == 1)
        await session.pause()
        session.reconnectAfterWake()
        #expect(session.phase == .paused)
        #expect(await feed.totalRuns == 2)
    }

    @Test func watchdogReconnectMessageKeepsAndRefreshesLastLivenessCheck() async throws {
        let store = MemoryGmailCredentials()
        let feed = ControlledGmailFeed()
        let account = IMAPAccount(provider: .gmail, email: "person@gmail.com")
        let name = "MailCodeFiller.watchdog.tests.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let session = GmailSession(
            account: account, vault: CandidateVault(), feed: feed,
            credentials: store, preferences: preferences)
        var starts = feed.starts.makeAsyncIterator()
        try session.connect(email: account.email, appPassword: "abcdefghijklmnop")
        #expect(await starts.next() == account.email)
        await feed.emit(.state(.listening))
        let lastSuccessfulCheck = try #require(session.lastSynchronizedAt)

        await feed.emit(.state(.reconnecting))
        #expect(session.message == "连接可能中断，正在重连；恢复后会补查最近邮件。")
        #expect(session.lastSynchronizedAt == lastSuccessfulCheck)

        try await Task.sleep(for: .milliseconds(20))
        await feed.emit(.state(.listening))
        #expect(session.lastSynchronizedAt! > lastSuccessfulCheck)
        await session.pause()
    }

    @Test func gmailAndQQSessionsListenTogetherAndRemovingOnePreservesOtherCandidates() async throws {
        let store = MemoryGmailCredentials()
        let vault = CandidateVault()
        let gmail = IMAPAccount(provider: .gmail, email: "person@gmail.com")
        let qq = IMAPAccount(provider: .qqMail, email: "person@qq.com")
        let gmailFeed = ControlledGmailFeed()
        let qqFeed = ControlledGmailFeed()
        let suite = "MailCodeFiller.multiple-session.tests.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let gmailSession = GmailSession(
            account: gmail, vault: vault, feed: gmailFeed, credentials: store, preferences: preferences)
        let qqSession = GmailSession(
            account: qq, vault: vault, feed: qqFeed, credentials: store, preferences: preferences)
        var gmailStarts = gmailFeed.starts.makeAsyncIterator()
        var qqStarts = qqFeed.starts.makeAsyncIterator()
        try gmailSession.connect(email: gmail.email, appPassword: "abcdefghijklmnop")
        try qqSession.connect(secret: "qq-authorization-code")
        #expect(await gmailStarts.next() == gmail.email)
        #expect(await qqStarts.next() == qq.email)
        await gmailFeed.emit(
            .message(
                ReceivedMail(
                    id: .init(account: gmail.id, mailbox: "INBOX", uidValidity: 1, uid: 1),
                    subject: "Gmail", bodies: ["Your verification code is 001234"],
                    sender: "GitHub <a@github.com>", receivedAt: Date())))
        await qqFeed.emit(
            .message(
                ReceivedMail(
                    id: .init(account: qq.id, mailbox: "INBOX", uidValidity: 2, uid: 2),
                    subject: "QQ", bodies: ["Your verification code is 654321"], sender: "QQ <a@qq.com>",
                    receivedAt: Date())))
        #expect(
            await vault.snapshot(now: Date()).map(\.id.message.account).sorted()
                == [gmail.id, qq.id].sorted())
        try await gmailSession.removeAccount()
        #expect(await vault.snapshot(now: Date()).map(\.id.message.account) == [qq.id])
        #expect(try store.load(accountID: qq.id)?.secret == "qq-authorization-code")
        await qqSession.pause()
    }

    @Test func beisenStandaloneCodePublishesLocallyWithoutCallingJev() async throws {
        let fixture = try semanticFixture()
        defer { fixture.preferences.removePersistentDomain(forName: fixture.name) }
        var starts = fixture.feed.starts.makeAsyncIterator()
        try fixture.session.connect(email: "person@gmail.com", appPassword: "abcdefghijklmnop")
        _ = await starts.next()
        await fixture.feed.emit(
            .message(
                ReceivedMail(
                    id: .init(account: "person@gmail.com", mailbox: "INBOX", uidValidity: 1, uid: 72),
                    subject: "用户验证码",
                    bodies: [
                        "您好!为确保账号安全，请使用以下验证码完成邮箱验证，验证码有效期为10分钟。\n\n771285\n\n如果您没有发起此操作，请忽略此邮件。"
                    ],
                    sender: "北森 <cfmee-noreply@talenton.com>", receivedAt: Date())))

        #expect(await fixture.vault.snapshot(now: Date()).compactMap(\.code) == ["771285"])
        #expect(await fixture.resolver.count == 0)
        #expect(fixture.session.recognitionNotice == nil)
        await fixture.session.pause()
    }

    @Test func slowSemanticWorkDoesNotBlockLocalCodesOrRepeatOnDuplicateMail() async throws {
        let fixture = try semanticFixture()
        defer { fixture.preferences.removePersistentDomain(forName: fixture.name) }
        let session = fixture.session
        let missed = RecentMissedMailRing()
        session.recentMissedMail = missed
        var starts = fixture.feed.starts.makeAsyncIterator()
        var requests = fixture.resolver.requests.makeAsyncIterator()
        try session.connect(email: "person@gmail.com", appPassword: "abcdefghijklmnop")
        _ = await starts.next()
        let unresolved = semanticMail(uid: 1, body: "Enter 483921 to finish signing in.")
        await fixture.feed.emit(.message(unresolved))
        #expect(await missed.snapshot().map(\.id) == [unresolved.id])
        #expect(await requests.next() == 1)
        let jobs = Array(session.semanticJobs.values)
        await fixture.feed.emit(.message(unresolved))
        await fixture.feed.emit(.message(semanticMail(uid: 2, body: "Your verification code is 001234")))
        #expect(await fixture.vault.snapshot(now: Date()).compactMap(\.code) == ["001234"])
        #expect(await fixture.resolver.count == 1)
        await fixture.resolver.finish(code: "483921")
        for job in jobs { await job.value }
        #expect(await missed.snapshot().isEmpty)
        #expect(Set(await fixture.vault.snapshot(now: Date()).compactMap(\.code)) == ["001234", "483921"])
        await session.pause()
    }

    @Test func magicLinkPublishesBeforeJevAndJevPayloadDoesNotGainHrefTargets() async throws {
        let fixture = try semanticFixture()
        defer { fixture.preferences.removePersistentDomain(forName: fixture.name) }
        var starts = fixture.feed.starts.makeAsyncIterator()
        var requests = fixture.resolver.requests.makeAsyncIterator()
        try fixture.session.connect(email: "person@gmail.com", appPassword: "abcdefghijklmnop")
        _ = await starts.next()

        let href = "https://login.example.test/magic?token=synthetic-bearer"
        let mail = ReceivedMail(
            id: .init(account: "person@gmail.com", mailbox: "INBOX", uidValidity: 1, uid: 41),
            subject: "Example", bodies: ["Enter 483921 to finish signing in."],
            links: [MailLink(href: href, text: "Sign in")], sender: "Example", receivedAt: Date())
        #expect(!JevMailInput(mail).state.body.contains(href))
        await fixture.feed.emit(.message(mail))
        #expect(await requests.next() == 41)
        let immediate = await fixture.vault.snapshot(now: Date())
        #expect(immediate.count == 1)
        #expect(immediate.first?.loginLink?.url.absoluteString == href)

        let jobs = Array(fixture.session.semanticJobs.values)
        await fixture.resolver.finish(code: "483921")
        for job in jobs { await job.value }
        let merged = await fixture.vault.snapshot(now: Date())
        #expect(merged.count == 2)
        #expect(merged.compactMap(\.code) == ["483921"])
        #expect(merged.compactMap(\.loginLink).count == 1)
        await fixture.session.pause()
    }

    @Test(arguments: [false, true])
    func cancelledSemanticResponseCannotPublishAfterPauseOrDisable(disable: Bool) async throws {
        let fixture = try semanticFixture()
        defer { fixture.preferences.removePersistentDomain(forName: fixture.name) }
        var starts = fixture.feed.starts.makeAsyncIterator()
        var requests = fixture.resolver.requests.makeAsyncIterator()
        try fixture.session.connect(email: "person@gmail.com", appPassword: "abcdefghijklmnop")
        _ = await starts.next()
        await fixture.feed.emit(.message(semanticMail(uid: 3, body: "Enter 483921 to finish signing in.")))
        _ = await requests.next()
        let jobs = Array(fixture.session.semanticJobs.values)
        if disable { fixture.session.setSemanticResolver(nil) } else { await fixture.session.pause() }
        await fixture.resolver.finish(code: "483921")
        for job in jobs { await job.value }
        #expect(await fixture.vault.snapshot(now: Date()).isEmpty)
        #expect(fixture.session.recognitionNotice == nil)
        await fixture.session.pause()
    }

    @Test func semanticFailureIsVisibleWithoutFailingTheMailConnection() async throws {
        let fixture = try semanticFixture()
        defer { fixture.preferences.removePersistentDomain(forName: fixture.name) }
        var starts = fixture.feed.starts.makeAsyncIterator()
        var requests = fixture.resolver.requests.makeAsyncIterator()
        try fixture.session.connect(email: "person@gmail.com", appPassword: "abcdefghijklmnop")
        _ = await starts.next()
        await fixture.feed.emit(.state(.listening))
        let href = "https://login.example.test/continue?token=private-token"
        let mail = ReceivedMail(
            id: .init(account: "person@gmail.com", mailbox: "INBOX", uidValidity: 1, uid: 5),
            subject: "Example", bodies: ["Enter 483921 to finish signing in."],
            links: [MailLink(href: href, text: "Continue")], sender: "Example", receivedAt: Date())
        #expect(JevMailInput(mail).candidates == ["483921"])
        #expect(!JevMailInput(mail).state.body.contains("private-token"))
        await fixture.feed.emit(.message(mail))
        #expect(await requests.next() == 5)
        let jobs = Array(fixture.session.semanticJobs.values)
        await fixture.resolver.fail()
        for job in jobs { await job.value }
        #expect(fixture.session.recognitionNotice == JevError.unavailable.errorDescription)
        let notice = try #require(fixture.session.recognitionNotice)
        #expect(!notice.contains("483921"))
        #expect(!notice.contains("private-token"))
        #expect(fixture.session.phase == .active(.listening))
        #expect(await fixture.vault.snapshot(now: Date()).isEmpty)
        await fixture.session.pause()
    }

    private func semanticMail(uid: UInt32, body: String) -> ReceivedMail {
        ReceivedMail(
            id: .init(account: "person@gmail.com", mailbox: "INBOX", uidValidity: 1, uid: uid),
            subject: "Example", bodies: [body], sender: "Example", receivedAt: Date())
    }

    private func semanticFixture() throws -> SemanticFixture {
        let name = "MailCodeFiller.semantic.tests.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: name))
        let vault = CandidateVault()
        let feed = ControlledGmailFeed()
        let resolver = ControlledSemanticResolver()
        let account = IMAPAccount(provider: .gmail, email: "person@gmail.com")
        let session = GmailSession(
            account: account, vault: vault, feed: feed, credentials: MemoryGmailCredentials(),
            preferences: preferences)
        session.setSemanticResolver(resolver)
        return SemanticFixture(
            name: name, preferences: preferences, vault: vault, feed: feed, resolver: resolver,
            session: session)
    }

    @Test func validationOrStorageFailureDoesNotStartAFeed() throws {
        let store = MemoryGmailCredentials()
        store.saveError = GmailAccountError.keychain(-1)
        let malformedAccount = IMAPAccount(provider: .gmail, email: "bad")
        let malformedSession = GmailSession(
            account: malformedAccount, vault: CandidateVault(), feed: ControlledGmailFeed(),
            credentials: store)
        #expect(throws: GmailAccountError.invalidEmail) {
            try malformedSession.connect(email: "bad", appPassword: "abcdefghijklmnop")
        }
        let validAccount = IMAPAccount(provider: .gmail, email: "person@gmail.com")
        let session = GmailSession(
            account: validAccount, vault: CandidateVault(), feed: ControlledGmailFeed(), credentials: store)
        #expect(throws: GmailAccountError.invalidAppPassword) {
            try session.connect(email: "person@gmail.com", appPassword: "not-a-google-app-password")
        }
        #expect(throws: GmailAccountError.keychain(-1)) {
            try session.connect(email: "person@gmail.com", appPassword: "abcdefghijklmnop")
        }
        #expect(session.phase == .notConfigured)
        #expect(session.email == "person@gmail.com")
    }
}

private final class MemoryGmailCredentials: IMAPAccountCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var logins: [String: IMAPAccountCredentials] = [:]
    private var failure: GmailAccountError?
    var saveError: GmailAccountError? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }
    func load(accountID: String) throws -> IMAPAccountCredentials? {
        lock.withLock { logins[accountID] }
    }
    func save(_ value: IMAPAccountCredentials, accountID: String) throws {
        try lock.withLock {
            if let failure { throw failure }
            logins[accountID] = value
        }
    }
    func remove(accountID: String) throws { lock.withLock { logins[accountID] = nil } }
}

private actor ControlledGmailFeed: GmailFeed {
    nonisolated let starts: AsyncStream<String>
    private let started: AsyncStream<String>.Continuation
    private var concurrentRuns = 0
    private(set) var totalRuns = 0
    private(set) var maximumConcurrentRuns = 0
    private(set) var callback: (@Sendable (GmailFeedEvent) async -> Void)?

    init() {
        (starts, started) = AsyncStream.makeStream()
    }

    func run(login: GmailLogin, onEvent: @escaping @Sendable (GmailFeedEvent) async -> Void) async throws {
        concurrentRuns += 1
        totalRuns += 1
        maximumConcurrentRuns = max(maximumConcurrentRuns, concurrentRuns)
        defer { concurrentRuns -= 1 }
        callback = onEvent
        let (lifetime, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        started.yield(login.email)
        for await _ in lifetime {}
    }

    func emit(_ event: GmailFeedEvent) async { await callback?(event) }
}

private struct SemanticFixture {
    let name: String
    let preferences: UserDefaults
    let vault: CandidateVault
    let feed: ControlledGmailFeed
    let resolver: ControlledSemanticResolver
    let session: GmailSession
}

private actor ControlledSemanticResolver: SemanticCodeResolver {
    nonisolated let requests: AsyncStream<UInt32>
    private let requested: AsyncStream<UInt32>.Continuation
    private var pending: CheckedContinuation<String?, Error>?
    private(set) var count = 0

    init() { (requests, requested) = AsyncStream.makeStream() }

    func code(in mail: ReceivedMail) async throws -> String? {
        count += 1
        return try await withCheckedThrowingContinuation {
            pending = $0
            requested.yield(mail.id.uid)
        }
    }

    func finish(code: String) {
        pending?.resume(returning: code)
        pending = nil
    }
    func fail() {
        pending?.resume(throwing: JevError.unavailable)
        pending = nil
    }
}
