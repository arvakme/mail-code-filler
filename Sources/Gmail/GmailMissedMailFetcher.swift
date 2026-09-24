import Foundation
import MailCodeCore
import SwiftMail

/// Reopens one message on a separate, short-lived read-only TLS connection.
public struct GmailMissedMailFetcher: IMAPMessageRefetching {
    private let hostOverride: String?
    private let port: Int
    private let security: MailTransportSecurity
    private let maxBodyBytes: Int
    private let microsoftTokens: (any MicrosoftAccessTokenProviding)?

    public init(
        maxBodyBytes: Int = 256 * 1024,
        microsoftTokens: (any MicrosoftAccessTokenProviding)? = nil
    ) {
        self.hostOverride = nil
        self.port = 993
        self.security = .implicitTLS
        self.maxBodyBytes = maxBodyBytes
        self.microsoftTokens = microsoftTokens
    }

    init(
        host: String, port: Int, security: MailTransportSecurity, maxBodyBytes: Int = 64 * 1024,
        microsoftTokens: (any MicrosoftAccessTokenProviding)? = nil
    ) {
        self.hostOverride = host
        self.port = port
        self.security = security
        self.maxBodyBytes = maxBodyBytes
        self.microsoftTokens = microsoftTokens
    }

    public func fetchReadOnly(login: IMAPAccountCredentials, message: MailCodeCore.MessageID) async throws
        -> ReceivedMail
    {
        guard login.accountID == message.account else { throw IMAPMessageRefetchError.accountMismatch }
        guard message.mailbox.caseInsensitiveCompare("INBOX") == .orderedSame else {
            throw IMAPMessageRefetchError.invalidMailbox
        }
        let valid = try IMAPAccountCredentials.validated(
            provider: login.provider, email: login.email, secret: login.secret)
        let host = try hostOverride ?? valid.provider.imapHost(for: valid.email)
        let server = IMAPServer(
            host: host, port: port, transportSecurity: security,
            certificateVerificationPolicy: .fullVerification,
            minimumTLSVersion: .tlsv12,
            parserLimits: IMAPParserLimits(bodySizeLimit: UInt64(maxBodyBytes) + 1))
        do {
            if valid.provider == .neteaseMail {
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                await server.setClientIdentification(
                    Identification(name: "Mail Code Filler", version: version))
            }
            try await server.connect()
            if valid.provider == .outlook {
                guard let microsoftTokens else { throw MicrosoftOAuthError.missingClientID }
                let token = try await microsoftTokens.accessToken(
                    accountID: valid.accountID, forceRefresh: false)
                do {
                    try await server.authenticateXOAUTH2(email: valid.email, accessToken: token)
                } catch {
                    guard Self.isAuthenticationError(error) else { throw error }
                    let refreshed = try await microsoftTokens.accessToken(
                        accountID: valid.accountID, forceRefresh: true)
                    try await server.authenticateXOAUTH2(email: valid.email, accessToken: refreshed)
                }
                await server.setXOAUTH2AccessTokenProvider(email: valid.email) {
                    try await microsoftTokens.accessToken(accountID: valid.accountID, forceRefresh: false)
                }
            } else {
                let usernames = try valid.provider.loginUsernames(for: valid.email)
                for (index, username) in usernames.enumerated() {
                    do {
                        try await server.login(username: username, password: valid.secret)
                        break
                    } catch {
                        guard index + 1 < usernames.count, Self.isAuthenticationError(error) else {
                            throw error
                        }
                    }
                }
            }
            let selection = try await server.examineMailbox("INBOX")
            guard selection.isReadOnly else { throw IMAPMessageRefetchError.invalidMailbox }
            guard message.uidValidity != 0, selection.uidValidity.value == message.uidValidity else {
                throw IMAPMessageRefetchError.uidValidityChanged
            }
            let uid = UID(message.uid)
            let infos = try await server.fetchMessageInfos(
                uidRange: uid...uid, options: [.envelope, .internalDate, .bodyStructure])
            guard let info = infos.first(where: { $0.uid?.value == message.uid }) else {
                throw IMAPMessageRefetchError.messageUnavailable
            }
            let parts = GmailMessageText.readOrder(info.parts)
            guard !parts.isEmpty else { throw IMAPMessageRefetchError.noText }
            var used = 0
            var fetched: [(GmailTextPart, Data)] = []
            for part in parts {
                let remaining = maxBodyBytes - used
                guard remaining > 0, part.size.map({ $0 <= remaining }) ?? true else {
                    throw IMAPMessageRefetchError.oversized
                }
                let data: Data
                do {
                    data = try await server.fetchPart(
                        section: part.section, of: uid, offset: 0, count: remaining + 1)
                } catch {
                    if GmailFetchLimit.isBound(error) { throw IMAPMessageRefetchError.oversized }
                    throw error
                }
                guard data.count <= remaining else { throw IMAPMessageRefetchError.oversized }
                used += data.count
                fetched.append((GmailTextPart(mime: part.contentType, transferEncoding: part.encoding), data))
            }
            guard
                case .message(let decoded) = GmailMessageText.decode(
                    subject: info.subject, sender: info.from, parts: fetched, maxBytes: maxBodyBytes)
            else { throw IMAPMessageRefetchError.noText }
            let result = ReceivedMail(
                id: message, subject: decoded.subject, bodies: decoded.bodies, links: decoded.links,
                sender: decoded.sender, receivedAt: info.internalDate ?? Date())
            try? await server.disconnect()
            return result
        } catch {
            try? await server.disconnect()
            throw error
        }
    }

    private static func isAuthenticationError(_ error: Error) -> Bool {
        guard let error = error as? IMAPError else { return false }
        switch error {
        case .loginFailed, .authFailed: return true
        default: return false
        }
    }
}
