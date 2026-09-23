import Foundation

struct GmailEnvelopeStamp: Equatable, Sendable {
    var uid: UInt32
    var internalDate: Date?
    var sequence: UInt32
}

struct GmailCatchupDecision: Equatable, Sendable {
    var fetchUIDs: [UInt32]
    var expiredUIDs: [UInt32]
    var undatedUIDs: [UInt32]
    /// INTERNALDATE is further ahead than `futureSkew`. The caller must not mark these handled.
    var futureUIDs: [UInt32]
    var receivedAt: [UInt32: Date]
    var incomplete: Bool
}

enum GmailCatchup {
    /// `stamps` are the newest sequence window already fetched. INTERNALDATE decides retention.
    /// A Date header is not an input. UIDs already handled for this UIDVALIDITY are left untouched.
    /// A date further ahead than `futureSkew` is returned in `futureUIDs` and is not fetched.
    /// The caller announces it and leaves the UID unhandled.
    static func decide(
        stamps: [GmailEnvelopeStamp],
        messageCount: Int,
        limit: Int,
        now: Date,
        retention: TimeInterval,
        futureSkew: TimeInterval,
        handled: Set<UInt32>
    ) -> GmailCatchupDecision {
        var fetch: [(uid: UInt32, date: Date, sequence: UInt32)] = []
        var expired: [UInt32] = []
        var undated: [UInt32] = []
        var future: [UInt32] = []
        var receivedAt: [UInt32: Date] = [:]

        for stamp in stamps where !handled.contains(stamp.uid) {
            guard let date = stamp.internalDate else {
                undated.append(stamp.uid)
                continue
            }
            let age = now.timeIntervalSince(date)
            if age < -futureSkew {
                future.append(stamp.uid)
            } else if age >= retention {
                expired.append(stamp.uid)
            } else {
                let received = min(date, now)
                fetch.append((stamp.uid, received, stamp.sequence))
                receivedAt[stamp.uid] = received
            }
        }

        fetch.sort { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.sequence > rhs.sequence
        }

        let truncated = messageCount > limit
        let oldestAge = stamps.compactMap(\.internalDate).min().map { now.timeIntervalSince($0) }
        let incomplete = truncated && (oldestAge == nil || oldestAge! < retention)

        return GmailCatchupDecision(
            fetchUIDs: fetch.map(\.uid),
            expiredUIDs: expired,
            undatedUIDs: undated,
            futureUIDs: future,
            receivedAt: receivedAt,
            incomplete: incomplete
        )
    }
}
