import Foundation

public struct AutoFillReader: Sendable {
    private let store: any AutoFillStore

    public init(store: any AutoFillStore) { self.store = store }

    public func entries(at now: Date, preferredDomains: [String]) throws -> [AutoFillEntry] {
        let entries = try store.loadSnapshot()?.currentEntries(at: now) ?? []
        return entries.sorted { lhs, rhs in
            let leftMatches = !Set(lhs.domains).isDisjoint(with: preferredDomains)
            let rightMatches = !Set(rhs.domains).isDisjoint(with: preferredDomains)
            if leftMatches != rightMatches { return leftMatches }
            return lhs.receivedAt > rhs.receivedAt
        }
    }

    public func resolve(id: String, domain: String? = nil, at now: Date) throws -> AutoFillEntry? {
        guard let entry = try store.loadSnapshot()?.entry(id: id, at: now) else { return nil }
        if let domain, !entry.domains.contains(domain) { return nil }
        return entry
    }
}
