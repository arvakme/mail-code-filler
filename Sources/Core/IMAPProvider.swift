import Foundation

public enum IMAPProvider: String, CaseIterable, Codable, Sendable {
    case gmail
    case qqMail = "qq"
    case icloudMail = "icloud"
    case neteaseMail = "netease"
    case outlook

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
        case .icloudMail:
            IMAPProviderDescriptor(
                provider: self, displayName: "iCloud 邮箱", host: "imap.mail.me.com", port: 993,
                credentialLabel: "Apple App 专用密码", credentialPlaceholder: "App 专用密码",
                credentialHelpText:
                    "使用 iCloud 邮箱地址和 App 专用密码。先开启双重认证，再到 account.apple.com → 登录和安全 → App 专用密码生成；不要填写 Apple 账户密码。",
                credentialHelpURL: URL(string: "https://support.apple.com/zh-cn/102654")!,
                supportsIDLE: true, allowsPollingFallback: true, inboxName: "INBOX",
                iconName: "envelope")
        case .neteaseMail:
            IMAPProviderDescriptor(
                provider: self, displayName: "网易邮箱（163 / 126 / yeah.net）", host: "imap.163.com", port: 993,
                credentialLabel: "客户端授权码", credentialPlaceholder: "客户端授权码",
                credentialHelpText:
                    "先登录网页版邮箱，在设置 → POP3/SMTP/IMAP 开启 IMAP；按提示完成验证并生成客户端授权码。填写完整邮箱地址和授权码，不是网页邮箱密码。",
                credentialHelpURL: URL(
                    string:
                        "https://help.mail.yeah.net/faqDetail.do?code=d7a5dc8471cd0c0e8b4b8f4f8e49998b374173cfe9171305fa1ce630d7f67ac2a5feb28b66796d3b"
                )!,
                supportsIDLE: true, allowsPollingFallback: true, inboxName: "INBOX",
                iconName: "envelope")
        case .outlook:
            IMAPProviderDescriptor(
                provider: self, displayName: "Outlook / Hotmail / Microsoft 365",
                host: "outlook.office365.com", port: 993,
                credentialLabel: "Microsoft 授权", credentialPlaceholder: "无需输入密码",
                credentialHelpText: "使用 Microsoft 登录授权，不输入邮箱密码。",
                credentialHelpURL: URL(
                    string:
                        "https://support.microsoft.com/en-us/outlook/pop-imap-and-smtp-settings-for-outlook-com"
                )!,
                supportsIDLE: true, allowsPollingFallback: true, inboxName: "INBOX",
                iconName: "envelope.badge.shield.half.filled")
        }
    }

    public func imapHost(for email: String) throws -> String {
        let domain = try validatedDomain(email)
        switch self {
        case .gmail: return descriptor.host
        case .outlook: return descriptor.host
        case .qqMail: return descriptor.host
        case .icloudMail:
            guard ["icloud.com", "me.com", "mac.com"].contains(domain) else {
                throw IMAPAccountError.unsupportedDomain
            }
            return descriptor.host
        case .neteaseMail:
            guard ["163.com", "126.com", "yeah.net"].contains(domain) else {
                throw IMAPAccountError.unsupportedDomain
            }
            return "imap.\(domain)"
        }
    }

    public func loginUsernames(for email: String) throws -> [String] {
        _ = try imapHost(for: email)
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if self == .icloudMail, let local = address.split(separator: "@").first {
            return [String(local), address]
        }
        return [address]
    }

    private func validatedDomain(_ email: String) throws -> String {
        let parts = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw IMAPAccountError.invalidEmail
        }
        return String(parts[1])
    }

    /// Keep Gmail's historical account value stable for AutoFill rules and message IDs.
    /// Other providers use a namespaced ID so identical addresses cannot collide.
    public func accountID(email: String) -> String {
        switch self {
        case .gmail: email
        case .qqMail: "qq:\(email)"
        case .icloudMail: "icloud:\(email)"
        case .neteaseMail: "netease:\(email)"
        case .outlook: "outlook:\(email)"
        }
    }
}

public struct IMAPProviderDescriptor: Equatable, Sendable {
    public let provider: IMAPProvider
    /// Compact name for one-line account rows; `displayName` stays the full picker label.
    public var shortName: String {
        switch provider {
        case .gmail: "Gmail"
        case .qqMail: "QQ 邮箱"
        case .icloudMail: "iCloud"
        case .neteaseMail: "网易邮箱"
        case .outlook: "Outlook"
        }
    }

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
