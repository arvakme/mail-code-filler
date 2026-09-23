import Foundation
import Synchronization
import Testing

@testable import MailCodeCore

@Suite(.serialized)
struct JevCodeResolverTests {
    @Test func beisenStandaloneCodeIsAJevProposalButHrefIsNotSentAsBodyText() {
        let href = "https://careers.example.test/activate?token=private-link"
        let input = JevMailInput(
            ReceivedMail(
                id: .init(account: "person@example.test", mailbox: "INBOX", uidValidity: 1, uid: 10),
                subject: "用户验证码",
                bodies: [
                    "您好!为确保账号安全，请使用以下验证码完成邮箱验证，验证码有效期为10分钟。\n\n771285\n\n如果您没有发起此操作，请忽略此邮件。"
                ],
                links: [MailLink(href: href, text: "激活")],
                sender: "北森 <cfmee-noreply@talenton.com>", receivedAt: Date()))

        #expect(input.candidates == ["771285"])
        #expect(input.state.body.contains("771285"))
        #expect(!input.state.body.contains(href))
        #expect(!input.state.body.contains("private-link"))
    }

    @Test func proposalsAreBoundedAndPreserveLiteralCodes() throws {
        let input = JevMailInput(mail("Enter aB12cD or 001234.\n> old 999999"))
        #expect(input.candidates == ["aB12cD", "001234"])
        let bounded = JevMailInput(mail(String(repeating: "no code ", count: 300) + " 567890"))
        #expect(bounded.state.body.count <= 1500)
        let clipped = JevMailInput(mail(String(repeating: " ", count: 1495) + "001234"))
        #expect(clipped.candidates.isEmpty)
        #expect(bounded.candidates.isEmpty)
        let many = JevMailInput(mail("1000 1001 1002 1003 1004 1005 1006 1007 1008"))
        #expect(many.candidates.count == 8)
        let request = try JSONEncoder().encode(input.request)
        let json = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
        #expect(Set(json.keys) == ["state", "model", "questions"])
    }

    @Test func responseCannotInventNormalizeOrAcceptLowConfidenceCodes() throws {
        let candidates = ["aB12cD", "001234"]
        #expect(try JevCodeResolver.decode(response(0.98, "001234"), candidates: candidates) == "001234")
        #expect(try JevCodeResolver.decode(response(0.79, "aB12cD"), candidates: candidates) == nil)
        #expect(try JevCodeResolver.decode(response(0.99, "none"), candidates: candidates) == nil)
        for choice in ["1234", "AB12CD", "888888"] {
            #expect(throws: JevError.invalidResponse) {
                try JevCodeResolver.decode(response(0.99, choice), candidates: candidates)
            }
        }
        #expect(throws: JevError.invalidResponse) {
            try JevCodeResolver.decode(response(1.1, "001234"), candidates: candidates)
        }
        #expect(throws: JevError.invalidResponse) {
            try JevCodeResolver.decode(Data("not json".utf8), candidates: candidates)
        }
    }

    @Test func httpFailureIsSanitizedAndNoCandidateMakesNoRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JevURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let resolver = JevCodeResolver(apiKey: "synthetic-key", session: session)
        JevURLProtocol.requests.withLock { $0 = 0 }
        #expect(try await resolver.code(in: mail("There is no token here")) == nil)
        #expect(JevURLProtocol.requests.withLock { $0 } == 0)
        await #expect(throws: JevError.unavailable) {
            try await resolver.code(in: mail("Enter 001234 to finish signing in"))
        }
        #expect(JevURLProtocol.requests.withLock { $0 } == 1)
        #expect(!JevError.unavailable.localizedDescription.contains("server-secret"))
    }

    @Test func environmentImportDoesNotExecuteShellExpressions() throws {
        #expect(
            try JevCredentialStore.keyFromEnvironmentFile("OTHER=x\nexport TYPESAFE_API_KEY='example-key'\n")
                == "example-key")
        for value in ["", "$(cat secret)", "`command`", "abc def", "abc\nxyz"] {
            #expect(throws: JevError.missingKey) { try JevCredentialStore.validated(value) }
        }
        #expect(throws: JevError.missingKey) {
            try JevCredentialStore.keyFromEnvironmentFile("OTHER_API_KEY=abc")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAIL_CODE_JEV_LIVE_TEST"] == "1"))
    func liveSyntheticMailOnly() async throws {
        let envFile = try #require(ProcessInfo.processInfo.environment["MAIL_CODE_JEV_ENV_FILE"])
        let key = try JevCredentialStore().importKey(from: URL(fileURLWithPath: envFile))
        let resolver = try JevCodeResolver(apiKey: key)
        let started = ContinuousClock.now
        let code = try await resolver.code(
            in: mail("Enter 483921 to finish signing in. Order reference: 772266."))
        #expect(code == "483921")
        print(
            "Jev synthetic positive request: \(started.duration(to: .now)); expected choice matched=\(code == "483921")"
        )
        let negative = try await resolver.code(
            in: mail("Your order number is 772266. Parcel number 483921. No action required."))
        #expect(negative == nil)
        print("Jev synthetic negative request: no OTP=\(negative == nil)")
    }

    private func mail(_ body: String) -> ReceivedMail {
        ReceivedMail(
            id: .init(account: "test@example.test", mailbox: "INBOX", uidValidity: 1, uid: 1),
            subject: "Example notification", bodies: [body], sender: "Example <noreply@example.test>",
            receivedAt: Date())
    }

    private func response(_ confidence: Double, _ choice: String) -> Data {
        Data("{\"answers\":{\"is_otp\":{\"noul\":\(confidence)},\"code\":{\"choice\":\"\(choice)\"}}}".utf8)
    }
}

private final class JevURLProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex(0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0 += 1 }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("server-secret".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
