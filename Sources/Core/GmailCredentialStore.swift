import Foundation
import LocalAuthentication
import Security

public enum IMAPAccountError: LocalizedError, Equatable {
    case invalidEmail
    case invalidAppPassword
    case invalidAuthorizationCode
    case invalidICloudPassword
    case invalidNetEaseAuthorizationCode
    case unsupportedDomain
    case keychain(OSStatus)
    case damagedCredential
    case credentialMismatch
    case migrationVerificationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidEmail:
            return "请输入完整的邮箱地址。"
        case .invalidAppPassword:
            return "请输入 Google 生成的 16 位应用专用密码，不是 Google 登录密码。"
        case .invalidAuthorizationCode:
            return "请输入 QQ 邮箱设置中生成的授权码，不是 QQ 密码。"
        case .invalidICloudPassword:
            return "请输入 Apple 账户生成的 App 专用密码，不是 Apple 账户密码。"
        case .invalidNetEaseAuthorizationCode:
            return "请输入网易邮箱设置中生成的客户端授权码，不是网页邮箱密码。"
        case .unsupportedDomain:
            return "所选邮箱类型不支持这个邮箱域名。"
        case .keychain:
            return "无法访问登录钥匙串。请解锁钥匙串后重试；凭据没有转存到文件。"
        case .damagedCredential:
            return "保存的邮箱凭据无法读取，请更新凭据后重试。"
        case .credentialMismatch:
            return "保存的凭据与邮箱账户不匹配，未删除旧凭据。"
        case .migrationVerificationFailed:
            return "新凭据写入后回读校验失败，旧凭据仍保留。"
        }
    }
}

public typealias GmailAccountError = IMAPAccountError

extension IMAPAccountCredentials {
    public static func validated(
        provider: IMAPProvider, email: String, secret: String
    ) throws -> IMAPAccountCredentials {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
            !address.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0)
                    || CharacterSet.controlCharacters.contains($0)
            })
        else { throw IMAPAccountError.invalidEmail }
        _ = try provider.imapHost(for: address)

        let compactSecret = secret.filter { !$0.isWhitespace }
        switch provider {
        case .gmail:
            guard compactSecret.utf8.count == 16,
                compactSecret.utf8.allSatisfy({
                    (65...90).contains($0) || (97...122).contains($0)
                })
            else { throw IMAPAccountError.invalidAppPassword }
        case .qqMail:
            guard !compactSecret.isEmpty,
                !compactSecret.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                })
            else { throw IMAPAccountError.invalidAuthorizationCode }
        case .icloudMail:
            guard !compactSecret.isEmpty,
                !compactSecret.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                })
            else { throw IMAPAccountError.invalidICloudPassword }
        case .neteaseMail:
            guard compactSecret.utf8.count == 16,
                compactSecret.utf8.allSatisfy({
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                })
            else { throw IMAPAccountError.invalidNetEaseAuthorizationCode }
        case .outlook:
            guard compactSecret.isEmpty else { throw IMAPAccountError.credentialMismatch }
        }
        return IMAPAccountCredentials(provider: provider, email: address, secret: compactSecret)
    }

    public static func validated(email: String, appPassword: String) throws -> IMAPAccountCredentials {
        try validated(provider: .gmail, email: email, secret: appPassword)
    }
}

public protocol IMAPAccountCredentialStore: Sendable {
    func load(accountID: String) throws -> IMAPAccountCredentials?
    func save(_ credentials: IMAPAccountCredentials, accountID: String) throws
    func remove(accountID: String) throws
}

public protocol LegacyGmailCredentialStore: Sendable {
    func load() throws -> IMAPAccountCredentials?
    func save(_ credentials: IMAPAccountCredentials) throws
    func remove() throws
}

public typealias GmailCredentialStore = LegacyGmailCredentialStore

/// New credentials are isolated per account in the login Keychain, outside AutoFill's access group.
public struct KeychainIMAPCredentialStore: IMAPAccountCredentialStore {
    private let service: String

    public init(service: String = "dev.zhijie.MailCodeFiller.imap.accounts") {
        self.service = service
    }

    public func load(accountID: String) throws -> IMAPAccountCredentials? {
        var query = identity(accountID: accountID)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw IMAPAccountError.keychain(status) }
        guard let data = result as? Data,
            let stored = try? JSONDecoder().decode(IMAPAccountCredentials.self, from: data),
            stored.accountID == accountID
        else { throw IMAPAccountError.damagedCredential }
        return stored
    }

    public func save(_ credentials: IMAPAccountCredentials, accountID: String) throws {
        guard credentials.accountID == accountID else { throw IMAPAccountError.credentialMismatch }
        let data = try JSONEncoder().encode(credentials)
        let status = SecItemUpdate(
            identity(accountID: accountID) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw IMAPAccountError.keychain(status) }
        var attributes = identity(accountID: accountID)
        attributes[kSecValueData] = data
        attributes[kSecAttrLabel] = "Mail Code Filler · \(credentials.provider.descriptor.displayName)"
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecSuccess else { throw IMAPAccountError.keychain(added) }
    }

    public func remove(accountID: String) throws {
        let status = SecItemDelete(identity(accountID: accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IMAPAccountError.keychain(status)
        }
    }

    private func identity(accountID: String) -> [CFString: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: accountID, kSecAttrSynchronizable: false,
            kSecUseAuthenticationContext: context,
        ]
    }
}

/// Access to the pre-multi-account Gmail item is used only by the migration path.
public struct KeychainGmailCredentialStore: LegacyGmailCredentialStore {
    private let service: String
    private let account = "primary-gmail"

    public init(service: String = "dev.zhijie.MailCodeFiller.gmail") {
        self.service = service
    }

    public func load() throws -> IMAPAccountCredentials? {
        var query = identity
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw IMAPAccountError.keychain(status) }
        guard let data = result as? Data,
            let stored = try? JSONDecoder().decode(StoredLogin.self, from: data)
        else { throw IMAPAccountError.damagedCredential }
        return IMAPAccountCredentials(email: stored.email, appPassword: stored.appPassword)
    }

    public func save(_ credentials: IMAPAccountCredentials) throws {
        guard credentials.provider == .gmail else { throw IMAPAccountError.credentialMismatch }
        let data = try JSONEncoder().encode(
            StoredLogin(email: credentials.email, appPassword: credentials.secret))
        let status = SecItemUpdate(identity as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw IMAPAccountError.keychain(status) }
        var attributes = identity
        attributes[kSecValueData] = data
        attributes[kSecAttrLabel] = "Mail Code Filler · Gmail"
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecSuccess else { throw IMAPAccountError.keychain(added) }
    }

    public func remove() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IMAPAccountError.keychain(status)
        }
    }

    private var identity: [CFString: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: account, kSecAttrSynchronizable: false,
            kSecUseAuthenticationContext: context,
        ]
    }

    private struct StoredLogin: Codable {
        let email: String
        let appPassword: String
    }
}

public enum GmailCredentialMigrationResult: Equatable, Sendable {
    case noLegacyCredential
    case migrated
    case cleanupPending
}

public enum GmailCredentialMigrator {
    /// The old item is kept unless a per-account write is read back byte-for-byte equivalent.
    /// If deleting the old item fails, startup can use the verified new item and retry next launch.
    public static func migrate(
        account: IMAPAccount,
        legacy: any LegacyGmailCredentialStore,
        perAccount: any IMAPAccountCredentialStore
    ) throws -> GmailCredentialMigrationResult {
        guard account.provider == .gmail, let old = try legacy.load() else {
            return .noLegacyCredential
        }
        guard old.provider == .gmail, old.email == account.email else {
            throw IMAPAccountError.credentialMismatch
        }

        let expected: IMAPAccountCredentials
        if let existing = try perAccount.load(accountID: account.id) {
            guard existing.provider == .gmail, existing.email == account.email else {
                throw IMAPAccountError.credentialMismatch
            }
            expected = existing
        } else {
            expected = old
            try perAccount.save(expected, accountID: account.id)
        }

        guard try perAccount.load(accountID: account.id) == expected else {
            throw IMAPAccountError.migrationVerificationFailed
        }
        do {
            try legacy.remove()
            return .migrated
        } catch {
            return .cleanupPending
        }
    }
}
