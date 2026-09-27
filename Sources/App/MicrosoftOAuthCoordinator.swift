import AppKit
import AuthenticationServices
import MailCodeCore

@MainActor
final class MicrosoftOAuthCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var listener: MicrosoftOAuthLoopbackListener?

    func authorize(
        client: MicrosoftOAuthTokenClient, onFallback: @MainActor () -> Void
    ) async throws -> (code: String, verifier: String, redirectURI: String) {
        guard session == nil, listener == nil else { throw MicrosoftOAuthError.authorizationFailed }
        let state = try MicrosoftOAuth.randomURLSafeString()
        let verifier = try MicrosoftOAuth.randomURLSafeString(byteCount: 64)
        let loopback = MicrosoftOAuthLoopbackListener(expectedState: state)
        if let redirectURI = try? loopback.start() {
            listener = loopback
            defer {
                listener = nil
                loopback.cancel()
            }
            try Task.checkCancellation()
            let url = client.authorizationURL(
                state: state, challenge: MicrosoftOAuth.challenge(for: verifier),
                redirectURI: redirectURI)
            guard NSWorkspace.shared.open(url) else {
                throw MicrosoftOAuthError.authorizationFailed
            }
            let code = try await loopback.waitForCode()
            return (code, verifier, redirectURI)
        }
        try Task.checkCancellation()
        onFallback()
        let url = client.authorizationURL(state: state, challenge: MicrosoftOAuth.challenge(for: verifier))
        let callback: URL = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: MicrosoftOAuth.callbackScheme,
                // AuthenticationServices calls back on an XPC queue; keep this closure nonisolated
                // (Swift 6 would otherwise infer @MainActor and trap) and hop to the main actor inside.
                completionHandler: { @Sendable [weak self] callback, error in
                    Task { @MainActor in
                        self?.session = nil
                        if error != nil {
                            continuation.resume(throwing: MicrosoftOAuthError.authorizationFailed)
                        } else if let callback {
                            continuation.resume(returning: callback)
                        } else {
                            continuation.resume(throwing: MicrosoftOAuthError.invalidCallback)
                        }
                    }
                })
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: MicrosoftOAuthError.authorizationFailed)
            }
        }
        return (
            try MicrosoftOAuth.authorizationCode(from: callback, expectedState: state),
            verifier, MicrosoftOAuth.redirectURI
        )
    }

    func cancel() {
        listener?.cancel()
        session?.cancel()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow()
    }
}
