import Foundation
import LocalAuthentication
import Security

public protocol AutoFillStore: Sendable {
    func loadSnapshot() throws -> AutoFillSnapshot?
    func saveSnapshot(_ snapshot: AutoFillSnapshot) throws
    func loadRules() throws -> [AutoFillRule]
    func saveRules(_ rules: [AutoFillRule]) throws
}

public struct KeychainAutoFillStore: AutoFillStore {
    private let accessGroup: String
    private let service = "dev.zhijie.MailCodeFiller.autofill"

    public init(accessGroup: String) throws {
        guard !accessGroup.isEmpty, !accessGroup.contains("$(") else {
            throw AutoFillError.missingConfiguration
        }
        self.accessGroup = accessGroup
    }

    public func loadSnapshot() throws -> AutoFillSnapshot? { try load(account: "candidates") }
    public func saveSnapshot(_ snapshot: AutoFillSnapshot) throws {
        try save(snapshot, account: "candidates")
    }
    public func loadRules() throws -> [AutoFillRule] { try load(account: "rules") ?? [] }
    public func saveRules(_ rules: [AutoFillRule]) throws { try save(rules, account: "rules") }

    private func load<Value: Decodable>(account: String) throws -> Value? {
        var query = identity(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AutoFillError.keychain(status) }
        guard let data = result as? Data else { throw AutoFillError.damagedSnapshot }
        do { return try JSONDecoder().decode(Value.self, from: data) } catch {
            throw AutoFillError.damagedSnapshot
        }
    }

    private func save(_ value: some Encodable, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let query = identity(account: account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw AutoFillError.keychain(status) }
        var attributes = query
        attributes[kSecValueData] = data
        attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecSuccess else { throw AutoFillError.keychain(added) }
    }

    private func identity(account: String) -> [CFString: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecAttrAccessGroup: accessGroup, kSecUseDataProtectionKeychain: true,
            kSecAttrSynchronizable: false, kSecUseAuthenticationContext: context,
        ]
    }
}
