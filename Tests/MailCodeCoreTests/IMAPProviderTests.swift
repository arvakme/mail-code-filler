import Foundation
import Testing

@testable import MailCodeCore

struct IMAPProviderTests {
    @Test func descriptorsAndAccountIdentityKeepGmailCompatible() {
        let gmail = IMAPProvider.gmail.descriptor
        #expect(gmail.host == "imap.gmail.com")
        #expect(gmail.port == 993)
        #expect(gmail.usesTLS)
        #expect(gmail.supportsIDLE)
        #expect(!gmail.allowsPollingFallback)
        #expect(IMAPProvider.gmail.accountID(email: "person@gmail.com") == "person@gmail.com")

        let qq = IMAPProvider.qqMail.descriptor
        #expect(qq.host == "imap.qq.com")
        #expect(qq.port == 993)
        #expect(qq.usesTLS)
        #expect(qq.supportsIDLE)
        #expect(qq.allowsPollingFallback)
        #expect(qq.credentialLabel.contains("授权码"))
        #expect(qq.credentialHelpText.contains("不是 QQ 密码"))
        #expect(IMAPProvider.qqMail.accountID(email: "person@qq.com") == "qq:person@qq.com")
        #expect(IMAPAccount(provider: .gmail, email: " Person@Gmail.com ").id == "person@gmail.com")
    }

    @Test func pauseAndAccountRecordsMigrateWithoutChangingGmailIdentity() throws {
        let suite = "MailCodeFiller.provider-tests.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let registry = IMAPAccountRegistry(preferences: preferences)
        let gmail = IMAPAccount(provider: .gmail, email: "person@gmail.com")
        preferences.set(true, forKey: IMAPAccountRegistry.legacyGmailPausedKey)
        registry.migrateLegacyGmailPause(for: gmail)
        #expect(registry.isPaused(gmail))
        #expect(preferences.object(forKey: IMAPAccountRegistry.legacyGmailPausedKey) == nil)
        registry.save([gmail, IMAPAccount(provider: .qqMail, email: "person@qq.com")])
        #expect(registry.load().contains(gmail))
        #expect(registry.load().contains { $0.id == "qq:person@qq.com" })
    }

    @Test func migrationWritesReadsBackThenDeletesLegacyCredential() throws {
        let login = IMAPAccountCredentials(email: "person@gmail.com", appPassword: "abcdefghijklmnop")
        let legacy = FakeLegacyCredentialStore(login: login)
        let perAccount = FakePerAccountCredentialStore()
        let account = IMAPAccount(provider: .gmail, email: login.email)
        #expect(
            try GmailCredentialMigrator.migrate(account: account, legacy: legacy, perAccount: perAccount)
                == .migrated)
        #expect(perAccount.order.suffix(2) == ["write", "read"])
        #expect(legacy.login == nil)
        #expect(try perAccount.load(accountID: account.id) == login)
    }

    @Test func failedLegacyDeletionKeepsVerifiedCredentialAndRetries() throws {
        let login = IMAPAccountCredentials(email: "person@gmail.com", appPassword: "abcdefghijklmnop")
        let legacy = FakeLegacyCredentialStore(login: login, removeFails: true)
        let perAccount = FakePerAccountCredentialStore()
        let account = IMAPAccount(provider: .gmail, email: login.email)
        #expect(
            try GmailCredentialMigrator.migrate(account: account, legacy: legacy, perAccount: perAccount)
                == .cleanupPending)
        #expect(legacy.login == login)
        #expect(try perAccount.load(accountID: account.id) == login)
        legacy.removeFails = false
        #expect(
            try GmailCredentialMigrator.migrate(account: account, legacy: legacy, perAccount: perAccount)
                == .migrated)
        #expect(legacy.login == nil)
    }

    @Test func verificationMismatchNeverDeletesLegacyCredential() throws {
        let login = IMAPAccountCredentials(email: "person@gmail.com", appPassword: "abcdefghijklmnop")
        let legacy = FakeLegacyCredentialStore(login: login)
        let perAccount = FakePerAccountCredentialStore(
            readbackOverride: .init(email: "person@gmail.com", appPassword: "ponmlkjihgfedcba"))
        let account = IMAPAccount(provider: .gmail, email: login.email)
        #expect(throws: IMAPAccountError.migrationVerificationFailed) {
            try GmailCredentialMigrator.migrate(account: account, legacy: legacy, perAccount: perAccount)
        }
        #expect(legacy.login == login)
    }
}

private final class FakeLegacyCredentialStore: LegacyGmailCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: IMAPAccountCredentials?
    private var fails: Bool

    init(login: IMAPAccountCredentials?, removeFails: Bool = false) {
        stored = login
        fails = removeFails
    }

    var login: IMAPAccountCredentials? { lock.withLock { stored } }
    var removeFails: Bool {
        get { lock.withLock { fails } }
        set { lock.withLock { fails = newValue } }
    }
    func load() throws -> IMAPAccountCredentials? { lock.withLock { stored } }
    func save(_ credentials: IMAPAccountCredentials) throws { lock.withLock { stored = credentials } }
    func remove() throws {
        try lock.withLock {
            if fails { throw IMAPAccountError.keychain(-1) }
            stored = nil
        }
    }
}

private final class FakePerAccountCredentialStore: IMAPAccountCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: IMAPAccountCredentials] = [:]
    private let readbackOverride: IMAPAccountCredentials?
    private var didWrite = false
    private var log: [String] = []

    init(readbackOverride: IMAPAccountCredentials? = nil) { self.readbackOverride = readbackOverride }
    var order: [String] { lock.withLock { log } }
    func load(accountID: String) throws -> IMAPAccountCredentials? {
        lock.withLock {
            log.append("read")
            return didWrite ? (readbackOverride ?? stored[accountID]) : stored[accountID]
        }
    }
    func save(_ credentials: IMAPAccountCredentials, accountID: String) throws {
        lock.withLock {
            log.append("write")
            stored[accountID] = credentials
            didWrite = true
        }
    }
    func remove(accountID: String) throws { lock.withLock { stored[accountID] = nil } }
}
