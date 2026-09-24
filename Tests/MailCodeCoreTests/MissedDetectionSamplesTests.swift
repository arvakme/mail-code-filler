import Foundation
import Testing

@testable import MailCodeCore

@Suite("Missed detection sample redaction")
struct MissedDetectionSamplesTests {
    @Test func redactsCodeEmailPhoneAndURLBeforeReview() throws {
        let mail = ReceivedMail(
            id: MessageID(account: "a", mailbox: "INBOX", uidValidity: 1, uid: 4),
            subject: "登录验证码",
            bodies: [
                "请登录 https://real.example/login/abc123?token=secret456 。验证码：Ab12Cd\n联系 test@real.example，电话 13800138000"
            ], sender: "Someone <test@real.example>", receivedAt: Date())
        var draft = MissedMailRedactor().makeDraft(from: mail)
        let body = draft.body.texts.joined()
        #expect(!body.contains("Ab12Cd"))
        #expect(!body.contains("test@"))
        #expect(!body.contains("13800138000"))
        #expect(!body.contains("secret456"))
        #expect(body.contains("https://example.invalid/login/"))
        #expect(draft.fromDomain == "real.example")
        #expect(throws: MissedSampleValidationError.self) {
            try MissedSampleValidator.validate(draft, reviewed: false)
        }
        MissedMailRedactor().markCode("Xx00Xx", in: &draft)
        #expect(draft.expected.codes == ["Xx00Xx"])
        try MissedSampleValidator.validate(draft, reviewed: true)
    }

    @Test func refusesUnredactedCodeAndExternalLink() {
        var sample = MissedDetectionSample(
            subject: "验证码", fromDomain: "example.test", mime: "text/plain",
            body: .text("验证码：123456"))
        #expect(throws: MissedSampleValidationError.self) {
            try MissedSampleValidator.validate(sample, reviewed: true)
        }
        sample.body = .text("验证码：000000")
        sample.expected.links = [.init(url: "https://real.example/login", purpose: "signIn")]
        #expect(throws: MissedSampleValidationError.self) {
            try MissedSampleValidator.validate(sample, reviewed: true)
        }
    }

    @Test func extractedLinkKeepsOnlySafeSemanticPath() throws {
        let mail = ReceivedMail(
            id: MessageID(account: "a", mailbox: "INBOX", uidValidity: 1, uid: 5),
            subject: "Sign in", bodies: ["Sign in with the link below"],
            links: [
                MailLink(
                    href: "https://real.example/login/private-token?tracking=secret",
                    text: "Sign in")
            ],
            sender: "Sender <sender@real.example>", receivedAt: Date())
        var draft = MissedMailRedactor().makeDraft(from: mail)
        let body = draft.body.texts.joined()
        #expect(body.contains("https://example.invalid/login/redacted"))
        #expect(!body.contains("private-token"))
        #expect(!body.contains("secret"))
        MissedMailRedactor().markLink(
            "https://example.invalid/login/redacted", purpose: "signIn", in: &draft)
        #expect(draft.expected.links.count == 1)
        try MissedSampleValidator.validate(draft, reviewed: true)
    }
}
