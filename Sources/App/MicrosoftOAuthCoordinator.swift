import AppKit
import AuthenticationServices
import MailCodeCore

@MainActor
final class MicrosoftOAuthCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func authorize(client: MicrosoftOAuthTokenClient) async throws -> (code: String, verifier: String) {
        guard session == nil else { throw MicrosoftOAuthError.authorizationFailed }
        let state = try MicrosoftOAuth.randomURLSafeString()
        let verifier = try MicrosoftOAuth.randomURLSafeString(byteCount: 64)
        let url = client.authorizationURL(state: state, challenge: MicrosoftOAuth.challenge(for: verifier))
        let callback: URL = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: MicrosoftOAuth.callbackScheme,
                completionHandler: { [weak self] callback, error in
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
        return (try MicrosoftOAuth.authorizationCode(from: callback, expectedState: state), verifier)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow()
    }
}
