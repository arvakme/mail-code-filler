import AppKit

public enum CandidateCopyError: LocalizedError {
    case expired
    case unavailable
    case notCode

    public var errorDescription: String? {
        switch self {
        case .expired: return "验证码已超过本地保留窗口，请等待新的验证码。"
        case .unavailable: return "剪贴板写入失败，请重新尝试。"
        case .notCode: return "这是链接候选，请使用卡片上的打开链接操作访问。"
        }
    }
}

@MainActor
public struct CandidateClipboard {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func copy(_ candidate: Candidate, now: Date = Date()) throws {
        guard candidate.expiresAt > now else { throw CandidateCopyError.expired }
        guard let code = candidate.code else { throw CandidateCopyError.notCode }
        pasteboard.clearContents()
        guard pasteboard.setString(code, forType: .string) else {
            throw CandidateCopyError.unavailable
        }
    }
}
