import Foundation

/// Persists account addresses and pause choices only; login credentials stay in Keychain.
public struct IMAPAccountRegistry {
    public static let accountsKey = "imap-accounts"
    public static let legacyGmailPausedKey = "gmail-listening-paused"

    private let preferences: UserDefaults

    public init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
    }

    public func load() -> [IMAPAccount] {
        guard let data = preferences.data(forKey: Self.accountsKey),
            let accounts = try? JSONDecoder().decode([IMAPAccount].self, from: data)
        else { return [] }
        var seen = Set<String>()
        return accounts.filter { seen.insert($0.id).inserted }
    }

    public func save(_ accounts: [IMAPAccount]) {
        let unique = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            .values.sorted { $0.id < $1.id }
        guard let data = try? JSONEncoder().encode(unique) else { return }
        preferences.set(data, forKey: Self.accountsKey)
    }

    public func isPaused(_ account: IMAPAccount) -> Bool {
        preferences.bool(forKey: Self.pausedKey(accountID: account.id))
    }

    public func setPaused(_ paused: Bool, for account: IMAPAccount) {
        preferences.set(paused, forKey: Self.pausedKey(accountID: account.id))
    }

    /// Migrates the former single-Gmail pause flag once, assigning it to the legacy account.
    public func migrateLegacyGmailPause(for account: IMAPAccount) {
        guard account.provider == .gmail,
            let legacyValue = preferences.object(forKey: Self.legacyGmailPausedKey)
        else { return }
        let key = Self.pausedKey(accountID: account.id)
        if preferences.object(forKey: key) == nil {
            preferences.set(legacyValue as? Bool ?? false, forKey: key)
        }
        preferences.removeObject(forKey: Self.legacyGmailPausedKey)
    }

    public static func pausedKey(accountID: String) -> String {
        "imap-account-paused.\(accountID)"
    }
}
