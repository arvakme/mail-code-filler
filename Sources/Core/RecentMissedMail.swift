import Foundation

public struct RecentMissedMail: Identifiable, Sendable, Equatable {
    public let id: MessageID
    public let senderDomain: String
    public let subject: String
    public let receivedAt: Date

    public init(id: MessageID, senderDomain: String, subject: String, receivedAt: Date) {
        self.id = id
        self.senderDomain = senderDomain
        self.subject = subject
        self.receivedAt = receivedAt
    }

    public init(mail: ReceivedMail) {
        self.init(
            id: mail.id, senderDomain: Self.domain(from: mail.sender),
            subject: mail.subject, receivedAt: mail.receivedAt)
    }

    private static func domain(from sender: String) -> String {
        let pattern = #"@[A-Za-z0-9.-]+"#
        guard let range = sender.range(of: pattern, options: .regularExpression) else {
            return "未知发件域"
        }
        return String(sender[range].dropFirst()).lowercased()
    }
}

/// Memory-only metadata for manual review. The ring never retains body, link or code text.
public actor RecentMissedMailRing {
    private let limit: Int
    private let retention: TimeInterval
    private let now: @Sendable () -> Date
    private var entries: [RecentMissedMail] = []

    public init(
        limit: Int = 50, retention: TimeInterval = 24 * 60 * 60,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(limit > 0 && retention > 0)
        self.limit = limit
        self.retention = retention
        self.now = now
    }

    public func record(_ mail: ReceivedMail) {
        let value = RecentMissedMail(mail: mail)
        prune()
        guard value.receivedAt <= now(), value.receivedAt.addingTimeInterval(retention) > now() else {
            return
        }
        entries.removeAll { $0.id == value.id }
        entries.insert(value, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    public func remove(_ id: MessageID) { entries.removeAll { $0.id == id } }
    public func remove(accountID: String) { entries.removeAll { $0.id.account == accountID } }
    public func clear() { entries.removeAll() }

    public func snapshot() -> [RecentMissedMail] {
        prune()
        return entries
    }

    private func prune() {
        let current = now()
        entries.removeAll {
            $0.receivedAt > current || $0.receivedAt.addingTimeInterval(retention) <= current
        }
    }
}

public protocol IMAPMessageRefetching: Sendable {
    func fetchReadOnly(login: IMAPAccountCredentials, message: MessageID) async throws -> ReceivedMail
}

public enum IMAPMessageRefetchError: LocalizedError, Sendable {
    case accountMismatch
    case invalidMailbox
    case uidValidityChanged
    case messageUnavailable
    case oversized
    case noText

    public var errorDescription: String? {
        switch self {
        case .accountMismatch: "账户与邮件不匹配，无法重新读取。"
        case .invalidMailbox: "只支持重新读取收件箱邮件。"
        case .uidValidityChanged: "邮箱标识已变化，无法安全地定位原邮件。"
        case .messageUnavailable: "邮件已移除或无法读取。"
        case .oversized: "邮件正文超过读取上限。"
        case .noText: "邮件没有可读取的文本。"
        }
    }
}
