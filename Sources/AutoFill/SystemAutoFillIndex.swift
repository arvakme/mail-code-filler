import AuthenticationServices
import Foundation

@MainActor
public struct SystemAutoFillIndex: AutoFillIdentityIndex {
    public init() {}

    public func isEnabled() async -> Bool { await ASCredentialIdentityStore.shared.state().isEnabled }

    public func replace(with snapshot: AutoFillSnapshot) async throws {
        try await ASCredentialIdentityStore.shared.replaceCredentialIdentities(
            Self.identities(for: snapshot, at: Date()))
    }

    static func identities(for snapshot: AutoFillSnapshot, at now: Date) -> [ASOneTimeCodeCredentialIdentity]
    {
        snapshot.currentEntries(at: now).flatMap { entry in
            entry.domains.map { domain in
                let identity = ASOneTimeCodeCredentialIdentity(
                    serviceIdentifier: ASCredentialServiceIdentifier(identifier: domain, type: .domain),
                    label: "\(entry.sender) · 邮件验证码", recordIdentifier: entry.id
                )
                identity.rank = Int(entry.receivedAt.timeIntervalSince1970)
                return identity
            }
        }
    }
}
