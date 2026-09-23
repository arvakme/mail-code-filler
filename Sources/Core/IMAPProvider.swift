import Foundation

public enum IMAPProvider: String, CaseIterable, Codable, Sendable {
    case gmail
    case qqMail = "qq"

    public var descriptor: IMAPProviderDescriptor {
        switch self {
        case .gmail:
            IMAPProviderDescriptor(
                provider: self,
                displayName: "Gmail",
                host: "imap.gmail.com",
                port: 993,
                credentialLabel: "Google 应用专用密码",
                credentialPlaceholder: "16 位应用专用密码",
                credentialHelpText:
                    "请在 Google 账号启用两步验证，再生成应用专用密码。不要填写 Google 登录密码。",
                credentialHelpURL: URL(string: "https://myaccount.google.com/apppasswords")!,
                supportsIDLE: true,
                allowsPollingFallback: false,
                inboxName: "INBOX",
                iconName: "envelope.badge.shield.half.filled")
        case .qqMail:
            IMAPProviderDescriptor(
                provider: self,
                displayName: "QQ 邮箱",
                host: "imap.qq.com",
                port: 993,
                credentialLabel: "QQ 邮箱授权码",
                credentialPlaceholder: "QQ 邮箱授权码",
                credentialHelpText:
                    "在 QQ 邮箱设置的账户或 POP3/IMAP/SMTP 服务区域启用 IMAP，并按页面提示生成授权码。页面入口名称可能随版本调整；授权码不是 QQ 密码。",
                credentialHelpURL: URL(string: "https://mail.qq.com/")!,
                supportsIDLE: true,
                allowsPollingFallback: true,
                inboxName: "INBOX",
                iconName: "envelope")
        }
    }

    /// Keep Gmail's historical account value stable for AutoFill rules and message IDs.
    /// Other providers use a namespaced ID so identical addresses cannot collide.
    public func accountID(email: String) -> String {
        switch self {
        case .gmail: email
        case .qqMail: "qq:\(email)"
        }
    }
}

public struct IMAPProviderDescriptor: Equatable, Sendable {
    public let provider: IMAPProvider
    public let displayName: String
    public let host: String
    public let port: Int
    public let credentialLabel: String
    public let credentialPlaceholder: String
    public let credentialHelpText: String
    public let credentialHelpURL: URL
    public let supportsIDLE: Bool
    public let allowsPollingFallback: Bool
    public let inboxName: String
    public let iconName: String
    public let usesTLS: Bool

    public init(
        provider: IMAPProvider, displayName: String, host: String, port: Int,
        credentialLabel: String, credentialPlaceholder: String, credentialHelpText: String,
        credentialHelpURL: URL, supportsIDLE: Bool, allowsPollingFallback: Bool,
        inboxName: String, iconName: String, usesTLS: Bool = true
    ) {
        self.provider = provider
        self.displayName = displayName
        self.host = host
        self.port = port
        self.credentialLabel = credentialLabel
        self.credentialPlaceholder = credentialPlaceholder
        self.credentialHelpText = credentialHelpText
        self.credentialHelpURL = credentialHelpURL
        self.supportsIDLE = supportsIDLE
        self.allowsPollingFallback = allowsPollingFallback
        self.inboxName = inboxName
        self.iconName = iconName
        self.usesTLS = usesTLS
    }
}

public struct IMAPAccount: Codable, Hashable, Identifiable, Sendable {
    public let provider: IMAPProvider
    public let email: String

    public var id: String { provider.accountID(email: email) }
    public var descriptor: IMAPProviderDescriptor { provider.descriptor }

    public init(provider: IMAPProvider, email: String) {
        self.provider = provider
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
