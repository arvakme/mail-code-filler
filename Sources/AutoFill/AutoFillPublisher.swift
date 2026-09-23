import Foundation
import MailCodeCore
import Observation

@MainActor
public protocol AutoFillIdentityIndex {
    func isEnabled() async -> Bool
    func replace(with snapshot: AutoFillSnapshot) async throws
}

public enum AutoFillState: Equatable {
    case checking
    case disabled
    case ready(suggestions: Int)
    case failed(String)
}

@MainActor @Observable
public final class AutoFillPublisher {
    public private(set) var state: AutoFillState = .checking
    public private(set) var rules: [AutoFillRule] = []
    @ObservationIgnored private let store: any AutoFillStore
    @ObservationIgnored private let index: any AutoFillIdentityIndex
    @ObservationIgnored private var candidates: [Candidate] = []
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var pending: (revision: Int, snapshot: AutoFillSnapshot)?
    @ObservationIgnored private var publishing: Task<Void, Never>?

    public init(store: any AutoFillStore, index: any AutoFillIdentityIndex) {
        self.store = store
        self.index = index
    }

    public func restore() throws { rules = try store.loadRules() }

    public func replaceCandidates(_ candidates: [Candidate], now: Date = Date()) throws {
        self.candidates = candidates
        revision += 1
        let snapshot = AutoFillSnapshot(candidates: candidates, rules: rules, now: now)
        do {
            // Persist first. An obsolete identity must never return a code missing from the latest snapshot.
            try store.saveSnapshot(snapshot)
            pending = (revision, snapshot)
            if publishing == nil {
                publishing = Task { await drain() }
            }
        } catch {
            pending = nil
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    public func addRule(for candidate: Candidate, domain: String) throws {
        let rule = try AutoFillRule(
            account: candidate.id.message.account, sender: candidate.source, domain: domain)
        guard
            !rules.contains(where: {
                $0.account == rule.account && $0.sender == rule.sender && $0.domain == rule.domain
            })
        else {
            // Rules may have persisted before an earlier projection write failed.
            try replaceCandidates(candidates)
            return
        }
        try saveRules(rules + [rule])
    }

    public func removeRule(id: AutoFillRule.ID) throws { try saveRules(rules.filter { $0.id != id }) }

    public func removeRules(account: String) throws {
        try saveRules(rules.filter { $0.account != account })
    }

    public func settle() async { await publishing?.value }

    private func saveRules(_ rules: [AutoFillRule]) throws {
        try store.saveRules(rules)
        self.rules = rules
        try replaceCandidates(candidates)
    }

    private func drain() async {
        while let publication = pending {
            pending = nil
            let enabled = await index.isEnabled()
            // The Keychain projection may have changed while the system answered.
            // Even a failed newer write invalidates this pending index request.
            guard revision == publication.revision else { continue }
            guard enabled else {
                state = .disabled
                continue
            }
            do {
                try await index.replace(with: publication.snapshot)
                if revision == publication.revision {
                    let count = publication.snapshot.currentEntries(at: Date()).filter { !$0.domains.isEmpty }
                        .count
                    state = .ready(suggestions: count)
                }
            } catch {
                if revision == publication.revision {
                    state = .failed(AutoFillError.identityUpdate.localizedDescription)
                }
            }
        }
        publishing = nil
    }
}
