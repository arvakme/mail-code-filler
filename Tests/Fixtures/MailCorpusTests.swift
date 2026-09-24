import Foundation
import MailCodeCore
import Testing

@testable import MailCodeGmail

private struct CorpusSample: Decodable {
    struct Expected: Decodable {
        struct Link: Decodable {
            let url: String
            let purpose: String
        }
        let codes: [String]
        let links: [Link]
    }

    enum Body: Decodable {
        case text(String)
        case parts(plain: String, html: String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else {
                let parts = try container.decode([String: String].self)
                self = .parts(plain: parts["plain"] ?? "", html: parts["html"] ?? "")
            }
        }
    }

    let subject: String
    let mime: String
    let body: Body
    let expected: Expected
    let source: String
}

@Suite("Synthetic mail regression corpus")
struct MailCorpusTests {
    @Test func decodesAndDetectsEveryFixture() throws {
        let urls = try #require(Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: nil))
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(urls.count >= 40)
        for url in urls {
            let sample = try JSONDecoder().decode(CorpusSample.self, from: Data(contentsOf: url))
            #expect(
                ["synthetic", "redacted-real"].contains(sample.source),
                "\(url.lastPathComponent)")
            let parts: [(GmailTextPart, Data)]
            switch sample.body {
            case .text(let text):
                parts = [(GmailTextPart(mime: sample.mime, transferEncoding: nil), Data(text.utf8))]
            case .parts(let plain, let html):
                parts = [
                    (GmailTextPart(mime: "text/plain", transferEncoding: nil), Data(plain.utf8)),
                    (GmailTextPart(mime: "text/html", transferEncoding: nil), Data(html.utf8)),
                ]
            }
            let outcome = GmailMessageText.decode(
                subject: sample.subject, sender: "fixture@example.test", parts: parts,
                maxBytes: 16_384)
            guard case .message(let decoded) = outcome else {
                Issue.record("Decode failed: \(url.lastPathComponent)")
                continue
            }
            let codes = CodeDetector().codes(subject: decoded.subject, bodies: decoded.bodies)
            #expect(codes == sample.expected.codes, "\(url.lastPathComponent)")
            let link = SignInLinkDetector().detect(
                subject: decoded.subject, bodies: decoded.bodies, links: decoded.links)
            if let expected = sample.expected.links.first {
                #expect(link?.url.absoluteString == expected.url, "\(url.lastPathComponent)")
                let purpose: String?
                switch link?.purpose {
                case .signIn: purpose = "signIn"
                case .activation: purpose = "activation"
                case .verification: purpose = "verification"
                case .accountNotice: purpose = "accountNotice"
                case nil: purpose = nil
                }
                #expect(purpose == expected.purpose, "\(url.lastPathComponent)")
            } else {
                #expect(link == nil, "\(url.lastPathComponent)")
            }
        }
    }
}
