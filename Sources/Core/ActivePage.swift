import Foundation

/// The frontmost browser page, reduced in memory to what ranking and code-wait triggers need.
/// Never stores the URL, path, query or fragment; callers must not log or persist it.
public struct ActivePage: Equatable, Sendable {
    public let registrableDomain: String
    public let host: String
    /// Path-keyword heuristic (login/signin/verify/otp/2fa/auth/登录/验证); not a trust signal.
    public let looksLikeAuthPage: Bool

    public init(registrableDomain: String, host: String, looksLikeAuthPage: Bool) {
        self.registrableDomain = registrableDomain
        self.host = host
        self.looksLikeAuthPage = looksLikeAuthPage
    }
}

@MainActor
public protocol ActivePageProviding: AnyObject {
    /// Reads on demand; returns nil when no supported browser page is frontmost or readable.
    func currentPage() -> ActivePage?
}
