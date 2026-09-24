import Foundation

/// Terminal failures for `IMAPAccountFeed`. Network loss stays inside `run` and surfaces as
/// `IMAPFeedEvent` reconnect state. Descriptions are fixed text: server replies are not copied.
public enum GmailIMAPError: Error, Equatable, Sendable {
    case authenticationRejected
    case idleUnavailable
    case mailboxNotReadOnly
    case rateLimited
}

extension GmailIMAPError: LocalizedError {
    public var errorDescription: String? { Self.sanitizedText(self) }

    public var failureReason: String? { Self.sanitizedText(self) }

    /// Fixed text only. Server replies, subjects, addresses, and passwords are never copied.
    private static func sanitizedText(_ error: GmailIMAPError) -> String {
        switch error {
        case .authenticationRejected:
            return "邮箱拒绝了登录。请确认 IMAP 已开启，并检查此服务对应的登录凭据。"
        case .idleUnavailable:
            return "邮箱服务器不支持 IDLE，且此提供方没有轮询回退。"
        case .mailboxNotReadOnly:
            return "INBOX 没有处于只读状态，已断开，避免改动邮件。"
        case .rateLimited:
            return "邮箱服务器限制了连接频率。已停止自动重试，请稍后手动重新连接。"
        }
    }
}
