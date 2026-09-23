import Foundation
import LocalAuthentication
import Security

public struct JevCredentialStore {
    public init() {}

    public func load() throws -> String? {
        var query = identity
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
            let key = String(data: data, encoding: .utf8)
        else { throw JevError.credential }
        return try Self.validated(key)
    }

    public func save(_ key: String) throws {
        let data = Data(try Self.validated(key).utf8)
        let status = SecItemUpdate(identity as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw JevError.credential }
        var attributes = identity
        attributes[kSecValueData] = data
        attributes[kSecAttrLabel] = "Mail Code Filler · Jev"
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw JevError.credential }
    }

    public func remove() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw JevError.credential }
    }

    /// Reads `TYPESAFE_API_KEY` from a user-chosen dotenv file; the file is parsed, never executed.
    public func importKey(from file: URL) throws -> String {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { throw JevError.missingKey }
        return try Self.keyFromEnvironmentFile(text)
    }

    static func keyFromEnvironmentFile(_ text: String) throws -> String {
        for line in text.split(separator: "\n") {
            var line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard line.hasPrefix("TYPESAFE_API_KEY=") else { continue }
            var value = String(line.dropFirst("TYPESAFE_API_KEY=".count)).trimmingCharacters(in: .whitespaces)
            if let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            return try validated(value)
        }
        throw JevError.missingKey
    }

    static func validated(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.allSatisfy({ (33...126).contains($0) }),
            !key.contains("$"), !key.contains("`"), !key.contains("\""), !key.contains("'")
        else { throw JevError.missingKey }
        return key
    }

    private var identity: [CFString: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass: kSecClassGenericPassword, kSecAttrService: "dev.zhijie.MailCodeFiller.jev",
            kSecAttrAccount: "typesafe", kSecAttrSynchronizable: false, kSecUseAuthenticationContext: context,
        ]
    }
}
