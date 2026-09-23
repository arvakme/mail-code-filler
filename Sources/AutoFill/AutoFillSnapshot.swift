import CryptoKit
import Foundation
import MailCodeCore
import Security

public struct AutoFillRule: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let account: String
    public let sender: String
    public let domain: String

    public init(account: String, sender: String, domain: String) throws {
        self.id = UUID()
        self.account = account
        self.sender = sender
        self.domain = try Self.normalizedDomain(domain)
    }

    public static func normalizedDomain(_ input: String) throws -> String {
        let domain = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard domain.utf8.count <= 253, labels.count >= 2,
            labels.allSatisfy({ label in
                !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                    && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
            }), labels.last!.utf8.contains(where: { (97...122).contains($0) })
        else { throw AutoFillError.invalidDomain }
        return domain
    }
}

public struct AutoFillEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let code: String
    public let account: String
    public let sender: String
    public let receivedAt: Date
    public let expiresAt: Date
    public let domains: [String]

    init(candidate: Candidate, code: String, rules: [AutoFillRule]) {
        // The system index is not secret storage: only an opaque identifier goes there.
        let message = candidate.id.message
        let components = [
            message.account, message.mailbox, String(message.uidValidity),
            String(message.uid), String(candidate.id.index),
        ]
        let framed = components.map { "\($0.utf8.count):\($0)" }.joined()
        id = SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
        self.code = code
        account = message.account
        sender = candidate.source
        receivedAt = candidate.receivedAt
        expiresAt = candidate.expiresAt
        domains = Array(
            Set(rules.filter { $0.account == message.account && $0.sender == candidate.source }.map(\.domain))
        ).sorted()
    }

    public func isCurrent(at now: Date) -> Bool {
        receivedAt <= now && now < expiresAt && now < receivedAt.addingTimeInterval(CandidateVault.retention)
    }
}

public struct AutoFillSnapshot: Codable, Equatable, Sendable {
    public let entries: [AutoFillEntry]

    public init(candidates: [Candidate], rules: [AutoFillRule], now: Date) {
        entries = candidates.compactMap { candidate in
            guard let code = candidate.code else { return nil }
            return AutoFillEntry(candidate: candidate, code: code, rules: rules)
        }.filter {
            $0.isCurrent(at: now)
        }
    }

    public func currentEntries(at now: Date) -> [AutoFillEntry] {
        entries.filter { $0.isCurrent(at: now) }
    }

    public func entry(id: String, at now: Date) -> AutoFillEntry? {
        entries.first { $0.id == id && $0.isCurrent(at: now) }
    }
}

public enum AutoFillError: LocalizedError, Equatable {
    case invalidDomain
    case missingConfiguration
    case keychain(Int32)
    case damagedSnapshot
    case identityUpdate

    public var errorDescription: String? {
        switch self {
        case .invalidDomain:
            return "请输入网站域名，例如 accounts.example.com；不包含 https://、路径或通配符。"
        case .missingConfiguration:
            return "此构建缺少 AutoFill 共享钥匙串配置，需要完成扩展签名。"
        case .keychain(let status) where status == errSecMissingEntitlement:
            return "系统未授予共享钥匙串权限，需要匹配宿主和扩展的 provisioning profile。"
        case .keychain:
            return "无法访问 AutoFill 钥匙串；请解锁这台 Mac 后重试，验证码没有转存到文件。"
        case .damagedSnapshot:
            return "AutoFill 候选数据无法读取，请打开主 App 重新同步。"
        case .identityUpdate:
            return "系统候选更新失败；请检查 AutoFill 设置后重试。"
        }
    }
}
