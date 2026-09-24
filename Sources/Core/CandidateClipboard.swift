import AppKit

public struct PasteboardWriteReceipt: Equatable, Sendable {
    public let changeCount: Int

    public init(changeCount: Int) {
        self.changeCount = changeCount
    }
}

/// The timer owns no code text. It only checks whether our pasteboard write is still current.
@MainActor
public final class ClipboardAutoClearScheduler {
    private let pasteboard: NSPasteboard
    private var pending: Task<Void, Never>?

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func schedule(_ receipt: PasteboardWriteReceipt, after seconds: Int) {
        cancel()
        guard [30, 60, 120].contains(seconds) else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.clearIfUnchanged(receipt)
        }
    }

    public func cancel() {
        pending?.cancel()
        pending = nil
    }

    @discardableResult
    public func clearIfUnchanged(_ receipt: PasteboardWriteReceipt) -> Bool {
        guard pasteboard.changeCount == receipt.changeCount else { return false }
        pasteboard.clearContents()
        pending = nil
        return true
    }
}

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
    public let autoClear: ClipboardAutoClearScheduler

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        autoClear = ClipboardAutoClearScheduler(pasteboard: pasteboard)
    }

    @discardableResult
    public func copy(
        _ candidate: Candidate, now: Date = Date(), autoClearSeconds: Int? = nil
    ) throws -> PasteboardWriteReceipt {
        guard candidate.expiresAt > now else { throw CandidateCopyError.expired }
        guard let code = candidate.code else { throw CandidateCopyError.notCode }
        autoClear.cancel()
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard pasteboard.setString(code, forType: .string) else {
            throw CandidateCopyError.unavailable
        }
        guard
            pasteboard.setString(
                "", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
            )
        else {
            pasteboard.clearContents()
            throw CandidateCopyError.unavailable
        }
        if autoClearSeconds != nil {
            guard
                pasteboard.setString(
                    "", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
                )
            else {
                pasteboard.clearContents()
                throw CandidateCopyError.unavailable
            }
        }
        let receipt = PasteboardWriteReceipt(changeCount: pasteboard.changeCount)
        if let autoClearSeconds {
            autoClear.schedule(receipt, after: autoClearSeconds)
        }
        return receipt
    }
}
