import CryptoKit
import Foundation
import LocalAuthentication
import Security

public enum MicrosoftOAuthError: LocalizedError, Equatable, Sendable {
    case missingClientID
    case invalidCallback
    case authorizationFailed
    case needsReauthentication
    case tokenRequestFailed
    case missingRefreshToken
    case keychain(OSStatus)
    /// The browser signed in a different Microsoft account than the mailbox entered in the app.
    case accountMismatch(signedIn: String, expected: String)

    public var errorDescription: String? {
        switch self {
        case .missingClientID: "请按 README 的 Outlook 邮箱说明填写 Client ID 并重新构建。"
        case .invalidCallback: "Microsoft 登录回调无效，请重新登录。"
        case .authorizationFailed: "Microsoft 登录未完成，请重试。"
        case .needsReauthentication, .missingRefreshToken: "需要重新登录 Microsoft 账户。"
        case .tokenRequestFailed: "暂时无法获取 Microsoft 登录令牌，请检查网络后重试。"
        case .keychain: "无法访问登录钥匙串，Microsoft 登录令牌未保存。"
        case .accountMismatch(let signedIn, let expected):
            "浏览器里登录的是 \(signedIn)，不是 \(expected)。请在登录页切换到 \(expected) 后重试。"
        }
    }
}

public enum MicrosoftOAuth {
    public static let redirectURI = "msauth.dev.zhijie.MailCodeFiller://auth"
    public static let callbackScheme = "msauth.dev.zhijie.MailCodeFiller"
    public static let scope = "https://outlook.office.com/IMAP.AccessAsUser.All offline_access"
    /// Sign-in also asks for an ID token so the app can confirm which account the browser used.
    public static let signInScope = "openid email profile " + scope

    /// Unverified read of the ID token's account name. It only guards against signing in the
    /// wrong account; the token came straight from Microsoft's token endpoint over TLS.
    public static func signedInAccount(idToken: String) -> String? {
        let parts = idToken.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let value = (json["email"] as? String) ?? (json["preferred_username"] as? String)
        return value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func clientID(bundle: Bundle = .main) -> String? {
        let value =
            (bundle.object(forInfoDictionaryKey: "MailCodeOutlookClientID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty || value.contains("YOUR_") ? nil : value
    }

    public static func randomURLSafeString(byteCount: Int = 32) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
            throw MicrosoftOAuthError.authorizationFailed
        }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func authorizationCode(
        from callback: URL, expectedState: String, redirectURI: String = redirectURI
    ) throws -> String {
        guard let redirect = URL(string: redirectURI),
            callback.scheme == redirect.scheme, callback.host == redirect.host,
            callback.port == redirect.port, callback.path == redirect.path,
            let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
            components.queryItems?.first(where: { $0.name == "state" })?.value == expectedState,
            let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
            !code.isEmpty
        else { throw MicrosoftOAuthError.invalidCallback }
        return code
    }
}

public struct MicrosoftTokenResponse: Decodable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Int
    public let idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case idToken = "id_token"
    }
}

public struct MicrosoftOAuthTokenClient: Sendable {
    private let clientID: String
    private let authority: URL
    private let session: URLSession
    private let loginHint: String?

    public init(
        clientID: String,
        authority: URL = URL(string: "https://login.microsoftonline.com/common")!,
        session: URLSession = .shared,
        loginHint: String? = nil
    ) {
        self.clientID = clientID
        self.authority = authority
        self.session = session
        self.loginHint = loginHint
    }

    /// Personal Microsoft account domains go straight to the consumer sign-in page, skipping the
    /// work/personal account discovery hop that can lose the browser session (AADSTS165000).
    public static func isConsumerDomain(_ email: String) -> Bool {
        guard let domain = email.split(separator: "@").last?.lowercased() else { return false }
        return ["outlook.com", "hotmail.com", "live.com", "msn.com", "passport.com"].contains(domain)
            || domain.hasPrefix("outlook.") || domain.hasPrefix("hotmail.") || domain.hasPrefix("live.")
    }

    public func authorizationURL(
        state: String, challenge: String, redirectURI: String = MicrosoftOAuth.redirectURI
    ) -> URL {
        var components = URLComponents(
            url: authority.appending(path: "oauth2/v2.0/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: MicrosoftOAuth.signInScope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if let loginHint {
            components.queryItems?.append(URLQueryItem(name: "login_hint", value: loginHint))
            if Self.isConsumerDomain(loginHint) {
                components.queryItems?.append(URLQueryItem(name: "domain_hint", value: "consumers"))
            }
        }
        return components.url!
    }

    public func exchange(
        code: String, verifier: String, redirectURI: String = MicrosoftOAuth.redirectURI
    ) async throws -> MicrosoftTokenResponse {
        try await request([
            "grant_type": "authorization_code", "client_id": clientID, "code": code,
            "code_verifier": verifier, "redirect_uri": redirectURI,
            "scope": MicrosoftOAuth.signInScope,
        ])
    }

    public func refresh(_ refreshToken: String) async throws -> MicrosoftTokenResponse {
        try await request([
            "grant_type": "refresh_token", "client_id": clientID,
            "refresh_token": refreshToken, "scope": MicrosoftOAuth.scope,
        ])
    }

    private func request(_ fields: [String: String]) async throws -> MicrosoftTokenResponse {
        var request = URLRequest(url: authority.appending(path: "oauth2/v2.0/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = fields.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            throw MicrosoftOAuthError.tokenRequestFailed
        }
        guard let http = response as? HTTPURLResponse else { throw MicrosoftOAuthError.tokenRequestFailed }
        guard (200..<300).contains(http.statusCode) else {
            // Only decode the error identifier; never surface server text or token data.
            let identifier = (try? JSONDecoder().decode(TokenError.self, from: data))?.error
            if identifier == "invalid_grant" { throw MicrosoftOAuthError.needsReauthentication }
            throw MicrosoftOAuthError.tokenRequestFailed
        }
        guard let token = try? JSONDecoder().decode(MicrosoftTokenResponse.self, from: data),
            !token.accessToken.isEmpty, token.expiresIn > 0
        else { throw MicrosoftOAuthError.tokenRequestFailed }
        return token
    }

    private struct TokenError: Decodable { let error: String }
}

public protocol MicrosoftRefreshTokenStoring: Sendable {
    func load(accountID: String) throws -> String?
    func save(_ token: String, accountID: String) throws
    func remove(accountID: String) throws
}

public struct KeychainMicrosoftRefreshTokenStore: MicrosoftRefreshTokenStoring {
    private let service: String

    public init(service: String = "dev.zhijie.MailCodeFiller.microsoft.refresh") {
        self.service = service
    }

    public func load(accountID: String) throws -> String? {
        var query = identity(accountID)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw MicrosoftOAuthError.keychain(status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8),
            !token.isEmpty
        else { throw MicrosoftOAuthError.needsReauthentication }
        return token
    }

    public func save(_ token: String, accountID: String) throws {
        let data = Data(token.utf8)
        let status = SecItemUpdate(identity(accountID) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw MicrosoftOAuthError.keychain(status) }
        var attributes = identity(accountID)
        attributes[kSecValueData] = data
        attributes[kSecAttrLabel] = "Mail Code Filler · Microsoft refresh token"
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecSuccess else { throw MicrosoftOAuthError.keychain(added) }
    }

    public func remove(accountID: String) throws {
        let status = SecItemDelete(identity(accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MicrosoftOAuthError.keychain(status)
        }
    }

    private func identity(_ accountID: String) -> [CFString: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: accountID, kSecAttrSynchronizable: false,
            kSecUseAuthenticationContext: context,
        ]
    }
}

public protocol MicrosoftAccessTokenProviding: Sendable {
    func accessToken(accountID: String, forceRefresh: Bool) async throws -> String
}

public actor MicrosoftOAuthTokenManager: MicrosoftAccessTokenProviding {
    private let client: MicrosoftOAuthTokenClient
    private let store: any MicrosoftRefreshTokenStoring
    private var accessTokens: [String: (value: String, expiresAt: Date)] = [:]
    private var refreshing: [String: Task<String, Error>] = [:]
    private var refreshGeneration: [String: UUID] = [:]

    public init(client: MicrosoftOAuthTokenClient, store: any MicrosoftRefreshTokenStoring) {
        self.client = client
        self.store = store
    }

    public func authorize(
        code: String, verifier: String, redirectURI: String = MicrosoftOAuth.redirectURI,
        accountID: String, expectedEmail: String? = nil
    ) async throws -> String? {
        let token = try await client.exchange(
            code: code, verifier: verifier, redirectURI: redirectURI)
        try Task.checkCancellation()
        // A Microsoft account can own several aliases, so a different sign-in name is not an error
        // by itself; the caller only surfaces it as a hint.
        var differentSignIn: String?
        if let expectedEmail, let idToken = token.idToken,
            let signedIn = MicrosoftOAuth.signedInAccount(idToken: idToken),
            signedIn != expectedEmail.lowercased()
        {
            differentSignIn = signedIn
        }
        guard let refresh = token.refreshToken, !refresh.isEmpty else {
            throw MicrosoftOAuthError.missingRefreshToken
        }
        refreshing[accountID]?.cancel()
        refreshing[accountID] = nil
        refreshGeneration[accountID] = nil
        try store.save(refresh, accountID: accountID)
        accessTokens[accountID] = (
            token.accessToken, Date().addingTimeInterval(TimeInterval(token.expiresIn))
        )
        return differentSignIn
    }

    public func accessToken(accountID: String, forceRefresh: Bool = false) async throws -> String {
        if let pending = refreshing[accountID] { return try await pending.value }
        if !forceRefresh, let cached = accessTokens[accountID],
            cached.expiresAt.timeIntervalSinceNow > 120
        {
            return cached.value
        }
        let generation = UUID()
        refreshGeneration[accountID] = generation
        let task = Task {
            try await performRefresh(accountID: accountID, generation: generation)
        }
        refreshing[accountID] = task
        defer {
            if refreshGeneration[accountID] == generation {
                refreshing[accountID] = nil
                refreshGeneration[accountID] = nil
            }
        }
        return try await task.value
    }

    private func performRefresh(accountID: String, generation: UUID) async throws -> String {
        guard let refresh = try store.load(accountID: accountID) else {
            throw MicrosoftOAuthError.needsReauthentication
        }
        do {
            let token = try await client.refresh(refresh)
            try Task.checkCancellation()
            guard refreshGeneration[accountID] == generation else { throw CancellationError() }
            // Persist a rotated refresh token before replacing the usable in-memory access token.
            if let rotated = token.refreshToken, !rotated.isEmpty {
                try store.save(rotated, accountID: accountID)
            }
            accessTokens[accountID] = (
                token.accessToken, Date().addingTimeInterval(TimeInterval(token.expiresIn))
            )
            return token.accessToken
        } catch MicrosoftOAuthError.needsReauthentication {
            accessTokens[accountID] = nil
            throw MicrosoftOAuthError.needsReauthentication
        }
    }

    public func remove(accountID: String) throws {
        refreshing[accountID]?.cancel()
        refreshing[accountID] = nil
        refreshGeneration[accountID] = nil
        try store.remove(accountID: accountID)
        accessTokens[accountID] = nil
    }
}
