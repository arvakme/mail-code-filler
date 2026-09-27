import Foundation

public struct IMAPAccountCredentials: Equatable, Codable, Sendable {
    public let provider: IMAPProvider
    public let email: String
    public let secret: String

    public var appPassword: String { secret }
    public var accountID: String { provider.accountID(email: email) }

    public init(provider: IMAPProvider, email: String, secret: String) {
        self.provider = provider
        self.email = email
        self.secret = secret
    }

    public init(email: String, appPassword: String) {
        provider = .gmail
        self.email = email
        secret = appPassword
    }
}

public typealias GmailLogin = IMAPAccountCredentials

public struct ReceivedMail: Sendable {
    public let id: MessageID
    public let subject: String
    /// MIME alternatives stay separate so signatures and code labels cannot cross body boundaries.
    public let bodies: [String]
    /// Extracted anchor targets stay separate from body text so code and Jev paths do not inherit hrefs.
    public let links: [MailLink]
    public let sender: String
    public let receivedAt: Date
    public let isFromJunk: Bool
    public let fetchMilliseconds: Double?

    public init(
        id: MessageID, subject: String, bodies: [String], links: [MailLink] = [], sender: String,
        receivedAt: Date, fetchMilliseconds: Double? = nil, isFromJunk: Bool = false
    ) {
        self.id = id
        self.subject = subject
        self.bodies = bodies
        self.links = links
        self.sender = sender
        self.fetchMilliseconds = fetchMilliseconds
        self.receivedAt = receivedAt
        self.isFromJunk = isFromJunk
    }
}

/// A provider-neutral normalized anchor. It remains untrusted until SignInLinkDetector validates it.
public struct MailLink: Equatable, Sendable {
    public let href: String
    public let text: String
    public let context: String

    public init(href: String, text: String, context: String = "") {
        self.href = href
        self.text = text
        self.context = context
    }
}

public enum IMAPFeedState: Sendable, Equatable {
    case connecting
    case synchronizing
    case listening
    case polling
    case reconnecting
}

public enum IMAPFeedEvent: Sendable {
    case state(IMAPFeedState)
    case message(ReceivedMail)
    case notice(String)
}

public typealias GmailFeedState = IMAPFeedState
public typealias GmailFeedEvent = IMAPFeedEvent

public protocol IMAPFeed: Sendable {
    /// Cancellation must close the active connection, including an outstanding IDLE command.
    func run(
        login: IMAPAccountCredentials,
        onEvent: @escaping @Sendable (IMAPFeedEvent) async -> Void
    ) async throws
}

public typealias GmailFeed = IMAPFeed
