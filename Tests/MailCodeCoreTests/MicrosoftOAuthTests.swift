import Foundation
import Testing

@testable import MailCodeCore

@Suite("Microsoft OAuth", .serialized)
struct MicrosoftOAuthTests {
    private let clientID = "00000000-1111-2222-3333-444444444444"

    @Test func authorizationUsesPKCEStateExactScopeAndRedirect() throws {
        let verifier = try MicrosoftOAuth.randomURLSafeString(byteCount: 64)
        let state = try MicrosoftOAuth.randomURLSafeString()
        let challenge = MicrosoftOAuth.challenge(for: verifier)
        #expect(verifier != state)
        #expect(challenge != verifier)
        let client = MicrosoftOAuthTokenClient(clientID: clientID)
        let url = client.authorizationURL(state: state, challenge: challenge)
        let query = Dictionary(
            uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                .map { ($0.name, $0.value ?? "") })
        #expect(url.host == "login.microsoftonline.com")
        #expect(url.path == "/common/oauth2/v2.0/authorize")
        #expect(query["client_id"] == clientID)
        #expect(query["scope"] == MicrosoftOAuth.signInScope)
        #expect(query["redirect_uri"] == MicrosoftOAuth.redirectURI)
        #expect(query["code_challenge"] == challenge)
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"] == state)
        #expect(query["client_secret"] == nil)
        let loopback = "http://localhost:49152"
        let browserURL = client.authorizationURL(
            state: state, challenge: challenge, redirectURI: loopback)
        let browserQuery = URLComponents(url: browserURL, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(browserQuery.first { $0.name == "redirect_uri" }?.value == loopback)
        let callback = URL(string: "\(MicrosoftOAuth.redirectURI)?code=synthetic-code&state=\(state)")!
        #expect(
            try MicrosoftOAuth.authorizationCode(from: callback, expectedState: state) == "synthetic-code")
        #expect(throws: MicrosoftOAuthError.invalidCallback) {
            try MicrosoftOAuth.authorizationCode(from: callback, expectedState: "wrong")
        }
    }

    @Test func exchangeRefreshRotationAndInvalidGrant() async throws {
        let server = FakeTokenURLProtocol.shared
        server.reset([
            (200, #"{"access_token":"first-access","refresh_token":"first-refresh","expires_in":3600}"#),
            (200, #"{"access_token":"second-access","refresh_token":"second-refresh","expires_in":3600}"#),
            (503, #"{"error":"temporarily_unavailable"}"#),
            (400, #"{"error":"invalid_grant","error_description":"private-token"}"#),
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeTokenURLProtocol.self]
        let client = MicrosoftOAuthTokenClient(
            clientID: clientID, session: URLSession(configuration: configuration))
        let store = MemoryRefreshStore()
        let manager = MicrosoftOAuthTokenManager(client: client, store: store)
        let account = "outlook:person@outlook.com"
        _ = try await manager.authorize(
            code: "synthetic-code", verifier: "synthetic-verifier",
            redirectURI: "http://localhost:49152", accountID: account)
        #expect(try store.load(accountID: account) == "first-refresh")
        #expect(try await manager.accessToken(accountID: account, forceRefresh: false) == "first-access")
        #expect(try await manager.accessToken(accountID: account, forceRefresh: true) == "second-access")
        #expect(try store.load(accountID: account) == "second-refresh")
        await #expect(throws: MicrosoftOAuthError.tokenRequestFailed) {
            try await manager.accessToken(accountID: account, forceRefresh: true)
        }
        #expect(try store.load(accountID: account) == "second-refresh")
        await #expect(throws: MicrosoftOAuthError.needsReauthentication) {
            try await manager.accessToken(accountID: account, forceRefresh: true)
        }
        #expect(MicrosoftOAuthError.needsReauthentication.localizedDescription == "需要重新登录 Microsoft 账户。")
        let requests = server.requests
        #expect(requests.count == 4)
        let exchange = try #require(requests.first)
        #expect(exchange["grant_type"] == "authorization_code")
        #expect(exchange["client_id"] == clientID)
        #expect(exchange["code_verifier"] == "synthetic-verifier")
        #expect(exchange["redirect_uri"] == "http://localhost:49152")
        #expect(exchange["scope"] == MicrosoftOAuth.signInScope)
        #expect(exchange["client_secret"] == nil)
        #expect(requests[1]["refresh_token"] == "first-refresh")
        #expect(requests[2]["refresh_token"] == "second-refresh")
        #expect(requests[3]["refresh_token"] == "second-refresh")
        try await manager.remove(accountID: account)
        #expect(try store.load(accountID: account) == nil)
    }

    @Test func keychainRefreshTokenIsPerAccountAndRemovable() throws {
        let store = KeychainMicrosoftRefreshTokenStore(service: "dev.zhijie.MailCodeFiller.test.\(UUID())")
        let first = "outlook:first@outlook.com"
        let second = "outlook:second@outlook.com"
        defer {
            try? store.remove(accountID: first)
            try? store.remove(accountID: second)
        }
        try store.save("synthetic-refresh-one", accountID: first)
        try store.save("synthetic-refresh-two", accountID: second)
        #expect(try store.load(accountID: first) == "synthetic-refresh-one")
        #expect(try store.load(accountID: second) == "synthetic-refresh-two")
        try store.save("synthetic-rotated", accountID: first)
        #expect(try store.load(accountID: first) == "synthetic-rotated")
        try store.remove(accountID: first)
        #expect(try store.load(accountID: first) == nil)
        #expect(try store.load(accountID: second) == "synthetic-refresh-two")
    }
}

private final class MemoryRefreshStore: MicrosoftRefreshTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]
    func load(accountID: String) throws -> String? { lock.withLock { tokens[accountID] } }
    func save(_ token: String, accountID: String) throws { lock.withLock { tokens[accountID] = token } }
    func remove(accountID: String) throws { lock.withLock { tokens[accountID] = nil } }
}

private final class FakeTokenURLProtocol: URLProtocol, @unchecked Sendable {
    static let shared = FakeTokenURLProtocolState()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.shared.next(request)
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class FakeTokenURLProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Int, String)] = []
    private var seen: [[String: String]] = []

    var requests: [[String: String]] { lock.withLock { seen } }

    func reset(_ values: [(Int, String)]) {
        lock.withLock {
            responses = values
            seen = []
        }
    }

    func next(_ request: URLRequest) -> (Int, String) {
        lock.withLock {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    data.append(contentsOf: bytes[..<count])
                }
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            let fields = URLComponents(string: "?\(body)")?.queryItems ?? []
            seen.append(Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value ?? "") }))
            return responses.removeFirst()
        }
    }

    @Test func personalAccountsGetLoginAndDomainHints() throws {
        let client = MicrosoftOAuthTokenClient(clientID: "client", loginHint: "person@outlook.com")
        let url = client.authorizationURL(state: "s", challenge: "c")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "login_hint", value: "person@outlook.com")))
        #expect(items.contains(URLQueryItem(name: "domain_hint", value: "consumers")))
        let work = MicrosoftOAuthTokenClient(clientID: "client", loginHint: "me@contoso.example")
        let workItems =
            URLComponents(
                url: work.authorizationURL(state: "s", challenge: "c"), resolvingAgainstBaseURL: false)?
            .queryItems ?? []
        #expect(!workItems.contains { $0.name == "domain_hint" })
    }

    @Test func idTokenAccountIsReadForMismatchCheck() {
        func segment(_ json: String) -> String {
            Data(json.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        let token = "\(segment("{}")).\(segment(#"{"email":"Other@Outlook.com"}"#)).sig"
        #expect(MicrosoftOAuth.signedInAccount(idToken: token) == "other@outlook.com")
        #expect(MicrosoftOAuth.signedInAccount(idToken: "opaque") == nil)
        let error = MicrosoftOAuthError.accountMismatch(signedIn: "a@outlook.com", expected: "b@outlook.com")
        #expect(error.errorDescription?.contains("b@outlook.com") == true)
    }
}
