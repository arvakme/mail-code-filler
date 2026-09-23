import Foundation

/// Tracks stack delivery separately from the list so reconnects cannot replay consumed mail.
public struct CandidateArrivalTracker: Sendable {
    private let startedAt: Date
    private var seen: [Candidate.ID: Date] = [:]
    private var promptedMessages: [MessageID: Date] = [:]
    private var quietMessages: [MessageID: Date] = [:]
    private var quietPeriods: [Date: DoNotDisturbPeriod] = [:]
    private var pending: [Candidate.ID: Date] = [:]

    /// `launchGrace` lets mail that landed just before launch (e.g. while the app was being
    /// restarted) still produce a card; older backfill stays list-only.
    public init(startedAt: Date = Date(), launchGrace: TimeInterval = 0) {
        self.startedAt = startedAt.addingTimeInterval(-max(0, launchGrace))
    }

    public struct Arrival: Sendable {
        /// All live stack rows, newest first. The view caps visible rows at five.
        public let candidates: [Candidate]
        /// Only the newest newly-arrived single-code message can be automatically copied.
        public let automaticCopy: Candidate?
    }

    public mutating func recordQuietPeriod(_ period: DoNotDisturbPeriod) {
        quietPeriods[period.startedAt] = period
    }

    public mutating func pendingCandidates(in candidates: [Candidate], now: Date) -> [Candidate] {
        let snapshot = Dictionary(
            candidates.filter { $0.expiresAt > now }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        pending = pending.filter { $0.value > now && snapshot[$0.key] != nil }
        return snapshot.values.filter { pending[$0.id] != nil }.sorted(by: Self.newerFirst)
    }

    public mutating func receive(
        _ candidates: [Candidate], now: Date, automaticCopyEnabled: Bool = false,
        quietPeriod: DoNotDisturbPeriod? = nil
    ) -> Arrival? {
        if let quietPeriod { recordQuietPeriod(quietPeriod) }
        seen = seen.filter { $0.value > now }
        promptedMessages = promptedMessages.filter { $0.value > now }
        quietMessages = quietMessages.filter { $0.value > now }
        pending = pending.filter { $0.value > now }
        quietPeriods = quietPeriods.filter { _, period in
            period.endsAt.map { $0.addingTimeInterval(CandidateVault.retention) > now }
                ?? period.isActive(at: now)
        }

        let snapshot = Dictionary(
            candidates.filter { $0.expiresAt > now }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let quietNow = quietPeriods.values.contains { $0.isActive(at: now) }
        var freshMessages: [MessageID: [Candidate]] = [:]

        for candidate in snapshot.values {
            let quietAtArrival =
                quietNow
                || quietPeriods.values.contains { $0.contains(arrivalAt: candidate.receivedAt) }
            if quietAtArrival { quietMessages[candidate.id.message] = candidate.expiresAt }
            if seen[candidate.id] == nil, candidate.receivedAt >= startedAt,
                !quietAtArrival, quietMessages[candidate.id.message] == nil,
                promptedMessages[candidate.id.message] == nil
            {
                freshMessages[candidate.id.message, default: []].append(candidate)
            }
            // Quiet and pre-launch identities are remembered, so neither can replay later.
            seen[candidate.id] = candidate.expiresAt
        }

        // Remove consumed, expired, paused, or account-removed rows from the pending stack.
        pending = pending.filter { snapshot[$0.key] != nil }
        guard !quietNow, !freshMessages.isEmpty else { return nil }

        var newlyPrompted: [Candidate] = []
        for (message, fresh) in freshMessages {
            let expiry =
                snapshot.values.filter { $0.id.message == message }.map(\.expiresAt).max()
                ?? fresh.map(\.expiresAt).max() ?? now
            promptedMessages[message] = expiry
            // Include siblings already present in this same delivery snapshot. A candidate
            // added later to this message is seen but does not open a second card.
            for candidate in snapshot.values where candidate.id.message == message {
                pending[candidate.id] = candidate.expiresAt
                newlyPrompted.append(candidate)
            }
        }

        let ordered = snapshot.values.filter { pending[$0.id] != nil }.sorted(by: Self.newerFirst)
        guard let newestArrival = newlyPrompted.sorted(by: Self.newerFirst).first else { return nil }
        let choicesFromNewestMessage = snapshot.values.filter {
            $0.id.message == newestArrival.id.message && $0.expiresAt > now
        }
        let automaticCopy =
            choicesFromNewestMessage.count == 1 && choicesFromNewestMessage[0].isCode
            ? choicesFromNewestMessage[0] : nil
        return Arrival(
            candidates: ordered,
            automaticCopy: automaticCopyEnabled ? automaticCopy : nil)
    }

    private static func newerFirst(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.receivedAt != rhs.receivedAt { return lhs.receivedAt > rhs.receivedAt }
        if lhs.id.message.account != rhs.id.message.account {
            return lhs.id.message.account < rhs.id.message.account
        }
        if lhs.id.message.uid != rhs.id.message.uid { return lhs.id.message.uid > rhs.id.message.uid }
        return lhs.id.index < rhs.id.index
    }
}
