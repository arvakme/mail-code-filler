import Foundation

public struct MessageID: Hashable, Sendable {
    public let account: String
    public let mailbox: String
    public let uidValidity: UInt32
    public let uid: UInt32

    public init(account: String, mailbox: String, uidValidity: UInt32, uid: UInt32) {
        self.account = account
        self.mailbox = mailbox
        self.uidValidity = uidValidity
        self.uid = uid
    }
}

public enum CandidateKind: Equatable, Sendable {
    case code(String)
    case loginLink(SignInLink)
}

public struct Candidate: Identifiable, Equatable, Sendable {
    public struct ID: Hashable, Sendable {
        public let message: MessageID
        public let index: Int
    }

    public let id: ID
    public let kind: CandidateKind
    public let source: String
    public let subject: String
    public let receivedAt: Date
    public let expiresAt: Date

    public var code: String? {
        guard case .code(let value) = kind else { return nil }
        return value
    }

    public var loginLink: SignInLink? {
        guard case .loginLink(let value) = kind else { return nil }
        return value
    }

    public var isCode: Bool { code != nil }
}

/// Authoritative in-process candidates; AutoFill publishes a short-lived Keychain projection.
public actor CandidateVault {
    public static let retention: TimeInterval = 10 * 60
    private var entries: [Candidate] = []
    private var processed: [MessageID: ProcessedMessage] = [:]

    private struct ProcessedMessage {
        var candidateIDs: Set<Candidate.ID>
        let expiresAt: Date
    }

    public init() {}

    public func insert(
        message: MessageID, codes: [String], loginLink: SignInLink? = nil,
        source: String, subject: String = "",
        receivedAt: Date, now: Date
    ) {
        expire(now: now)
        let expiry = receivedAt.addingTimeInterval(Self.retention)
        guard receivedAt <= now, expiry > now else { return }
        // Calls are merge batches, not a completion marker: a quick link can be
        // published before Jev returns a code. Candidate IDs make repeats idempotent.
        let existing = Set(entries.map(\.id))
        let consumed = processed[message]?.candidateIDs ?? []
        var additions = codes.enumerated().compactMap { index, code -> Candidate? in
            let id = Candidate.ID(message: message, index: index)
            guard !existing.contains(id), !consumed.contains(id) else { return nil }
            return Candidate(
                id: id, kind: .code(code), source: source, subject: subject,
                receivedAt: receivedAt, expiresAt: expiry
            )
        }
        if let loginLink {
            let id = Candidate.ID(message: message, index: -1)
            if !existing.contains(id), !consumed.contains(id) {
                additions.append(
                    Candidate(
                        id: id, kind: .loginLink(loginLink), source: source, subject: subject,
                        receivedAt: receivedAt, expiresAt: expiry
                    ))
            }
        }
        entries += additions
        entries.sort { $0.receivedAt > $1.receivedAt }
    }

    public func snapshot(now: Date) -> [Candidate] {
        expire(now: now)
        return entries
    }

    public func candidate(id: Candidate.ID, now: Date) -> Candidate? {
        expire(now: now)
        return entries.first { $0.id == id }
    }

    @discardableResult
    public func consume(
        id: Candidate.ID, afterSuccessfulAction: Bool, now: Date
    ) -> Candidate? {
        expire(now: now)
        guard afterSuccessfulAction,
            let index = entries.firstIndex(where: { $0.id == id })
        else { return nil }
        let candidate = entries.remove(at: index)
        let message = candidate.id.message
        var record =
            processed[message]
            ?? ProcessedMessage(
                candidateIDs: [], expiresAt: candidate.expiresAt)
        record.candidateIDs.insert(id)
        processed[message] = record
        return candidate
    }

    public func remove(account: String) {
        entries.removeAll { $0.id.message.account == account }
        processed = processed.filter { $0.key.account != account }
    }

    private func expire(now: Date) {
        entries.removeAll { $0.expiresAt <= now }
        processed = processed.filter { $0.value.expiresAt > now }
    }
}

public struct CandidateSelection: Sendable {
    public private(set) var id: Candidate.ID?

    public init() {}

    public mutating func select(_ id: Candidate.ID) { self.id = id }

    public mutating func reconcile(with candidates: [Candidate]) {
        // Disappearance must require another explicit selection, not redirect Return to a new code.
        if !candidates.contains(where: { $0.id == id }) { id = nil }
    }
}
