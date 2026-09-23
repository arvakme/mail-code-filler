import Foundation
import Logging
import MailCodeCore
import SwiftMail
import Testing

@testable import MailCodeGmail

@Suite("MailCodeGmailTests.Decoder")
struct GmailMessageTextTests {
    @Test func decodesBase64UTF8QuotedPrintableHTMLAndHeaders() {
        let plain = Data("verification code is 654321\n".utf8).base64EncodedData()
        let base64 = GmailMessageText.decode(
            subject: "=?UTF-8?B?6aqM6K+B56CB?=",
            sender: "=?UTF-8?B?5rWL6K+V?= <codes@example.test>",
            parts: [
                (
                    GmailTextPart(
                        mime: "text/plain; charset=utf-8", transferEncoding: "base64"), plain
                )
            ], maxBytes: 8_000)
        guard case .message(let decoded) = base64 else {
            Issue.record("base64 body was not decoded")
            return
        }
        #expect(decoded.subject == "验证码")
        #expect(decoded.sender.contains("测试"))
        #expect(decoded.bodies.contains { $0.contains("654321") })

        let quoted = GmailMessageText.decode(
            subject: "Cafe",
            sender: "cafe@example.test",
            parts: [
                (
                    GmailTextPart(
                        mime: "text/plain; charset=utf-8", transferEncoding: "quoted-printable"),
                    Data("caf=C3=A9 verification code is 135790".utf8)
                )
            ], maxBytes: 8_000)
        guard case .message(let qp) = quoted else {
            Issue.record("quoted-printable body was not decoded")
            return
        }
        #expect(qp.bodies.contains { $0.contains("café") })
        #expect(qp.bodies.contains { $0.contains("135790") })

        let html = GmailMessageText.decode(
            subject: "HTML",
            sender: "html@example.test",
            parts: [
                (
                    GmailTextPart(
                        mime: "text/html; charset=UTF-8", transferEncoding: "8bit"),
                    Data(
                        "<html><body><p>verification code is 111222</p><script>alert(1)</script> A&amp;B</body></html>"
                            .utf8)
                )
            ],
            maxBytes: 8_000)
        guard case .message(let page) = html else {
            Issue.record("html body was not decoded")
            return
        }
        #expect(page.bodies.contains { $0.contains("111222") })
        #expect(!page.bodies.contains { $0.contains("alert") })
        #expect(page.bodies.contains { $0.contains("A&B") })
    }

    @Test func failedTransferOrCharsetIsANotice() {
        let badBase64 = GmailMessageText.decode(
            subject: "Broken", sender: "a@example.test",
            parts: [
                (
                    GmailTextPart(
                        mime: "text/plain; charset=utf-8", transferEncoding: "base64"), Data("!!!!".utf8)
                )
            ], maxBytes: 8_000)
        #expect(badBase64 == .notice(GmailNotice.undecodable))

        let badUTF8 = GmailMessageText.decode(
            subject: "Broken", sender: "a@example.test",
            parts: [
                (
                    GmailTextPart(
                        mime: "text/plain; charset=utf-8", transferEncoding: "7bit"), Data([0xFF, 0xFE])
                )
            ], maxBytes: 8_000)
        #expect(badUTF8 == .notice(GmailNotice.undecodable))

        let partial = GmailMessageText.decode(
            subject: "Login", sender: "a@example.test",
            parts: [
                (GmailTextPart(mime: "text/plain"), Data([0xFF, 0xFE])),
                (GmailTextPart(mime: "text/html"), Data("<p>verification code is 654321</p>".utf8)),
            ], maxBytes: 8_000)
        guard case .message(let readable) = partial else {
            Issue.record("Readable alternative was lost")
            return
        }
        #expect(readable.hasUndecodablePart)
        #expect(CodeDetector().codes(subject: readable.subject, bodies: readable.bodies) == ["654321"])

        let unknown = GmailMessageText.decode(
            subject: "=?UTF-8?B?@@@?=", sender: "a@example.test",
            parts: [
                (
                    GmailTextPart(
                        mime: "text/plain; charset=utf-8", transferEncoding: "7bit"),
                    Data("verification code is 222333".utf8)
                )
            ], maxBytes: 8_000)
        guard case .message(let mail) = unknown else {
            Issue.record("readable body was dropped with the subject")
            return
        }
        #expect(mail.subject == "（主题无法解码）")
        #expect(mail.bodies.contains { $0.contains("222333") })
    }

    @Test func readsFirstPlainAndHTMLAndSkipsAttachments() {
        let parts = [
            mimePart([1], "text/html; charset=utf-8"),
            mimePart([2], "text/plain; charset=utf-8"),
            mimePart([3], "application/pdf", disposition: "attachment"),
        ]
        #expect(GmailMessageText.readOrder(parts).map(\.section.description) == ["2", "1"])
        #expect(GmailMessageText.readOrder([parts[2]]).isEmpty)
    }

    @Test func ignoresTextInsideAttachedForward() {
        let parts = [
            mimePart([1], "text/plain"),
            mimePart([2], "message/rfc822", disposition: "attachment"),
            mimePart([2, 1], "text/html"),
            mimePart([2, 1, 1], "text/plain"),
        ]
        #expect(GmailMessageText.readOrder(parts).map(\.section.description) == ["1"])
        #expect(GmailMessageText.readOrder([parts[1], parts[2], parts[3]]).isEmpty)
    }

    @Test func htmlDropsQuotedSubtreesAndBoundsEntities() {
        let html = """
            <p>Your verification code is 111222</p>
            <blockquote><p>Your verification code is 999999</p>
            <blockquote>Your verification code is 666666</blockquote></blockquote>
            <div class="gmail_quote gmail_quote_container">
              <div dir="ltr">On Monday someone wrote:</div>
              <div>Your verification code is 888888</div>
            </div>
            <p>A&amp;B</p>
            """
        let rendered = GmailMessageText.htmlToText(html)
        #expect(rendered.contains("111222"))
        #expect(rendered.contains("A&B"))
        #expect(!rendered.contains("999999"))
        #expect(!rendered.contains("666666"))
        #expect(!rendered.contains("888888"))
        #expect(CodeDetector().codes(subject: "Login", body: rendered) == ["111222"])
        #expect(GmailMessageText.htmlToText("&notanentitytoolong;") == "&notanentitytoolong;")
    }

    @Test func htmlQuoteAttributesRespectWhitespaceAndQuotedValues() {
        let wrappers = [
            #"<div class = "gmail_quote">"#,
            #"<div title=">" class='gmail_quote_container'>"#,
            #"<div CLASS = gmail_quote>"#,
        ]
        for wrapper in wrappers {
            let html =
                "<p>Your verification code is 111222</p>"
                + wrapper + "Your verification code is 999999</div>"
            #expect(
                CodeDetector().codes(subject: "Login", body: GmailMessageText.htmlToText(html)) == ["111222"])
        }
        let ownBody =
            #"<div data-class="gmail_quote" title="class='gmail_quote'">Your verification code is 111222</div>"#
        #expect(GmailMessageText.htmlToText(ownBody) == "Your verification code is 111222")
    }

    @Test func extractsVisibleHTMLAnchorsWithoutQuotedOrScriptTargets() throws {
        let html = #"""
            <p>Sign in to Claude</p>
            <p><a href="https://auth.claude.ai/login?token=secret&amp;next=%2F"><strong>Continue</strong> to Claude</a></p>
            <p><a href="https://claude.ai/help">Help center</a></p>
            <div class="gmail_quote"><a href="https://old.example.test/login?token=quoted">Sign in</a></div>
            <script><a href="https://tracker.example.test/pixel?token=script">Sign in</a></script>
            <img src="https://images.example.test/pixel.gif" />
            """#
        let outcome = GmailMessageText.decode(
            subject: "Sign in to Claude", sender: "Claude <noreply@claude.ai>",
            parts: [(GmailTextPart(mime: "text/html; charset=utf-8"), Data(html.utf8))],
            maxBytes: 8_000)
        guard case .message(let mail) = outcome else {
            Issue.record("HTML body was not decoded")
            return
        }

        #expect(mail.links.count == 2)
        #expect(mail.links[0].href == "https://auth.claude.ai/login?token=secret&next=%2F")
        #expect(mail.links[0].text == "Continue to Claude")
        #expect(mail.links[0].context.contains("Sign in to Claude"))
        #expect(!mail.links[0].context.contains("token=secret"))
        #expect(mail.links[1].text == "Help center")
        #expect(!mail.bodies.joined(separator: "\n").contains("token=secret"))
        #expect(!mail.links.contains { $0.href.contains("quoted") || $0.href.contains("script") })

        let login = SignInLinkDetector().detect(
            subject: mail.subject, bodies: mail.bodies, links: mail.links)
        #expect(login?.host == "auth.claude.ai")
    }

    @Test func decodedAccountActivationAnchorBecomesAnActivationCandidate() throws {
        let href = "https://careersite.example.test/cummins/user/activate?activationCode=fixture-token"
        let html = """
            <p>您好：jobs@example.test 感谢关注 康明斯 招聘官网，您的账号已经生成，请在30分钟内点击 <a href="\(href)">激活</a>。</p>
            """
        let outcome = GmailMessageText.decode(
            subject: "康明斯 账户激活通知", sender: "Cummins <service@example.test>",
            parts: [(GmailTextPart(mime: "text/html; charset=utf-8"), Data(html.utf8))],
            maxBytes: 8_000)
        guard case .message(let mail) = outcome else {
            Issue.record("HTML activation message was not decoded")
            return
        }

        #expect(mail.links.count == 1)
        #expect(mail.links[0].text == "激活")
        #expect(mail.links[0].href == href)
        #expect(!mail.bodies.joined(separator: "\n").contains("fixture-token"))
        let candidate = SignInLinkDetector().detect(
            subject: mail.subject, bodies: mail.bodies, links: mail.links)
        #expect(candidate?.purpose == .activation)
        #expect(candidate?.purpose.actionLabel == "打开激活链接")
    }

    private func mimePart(_ section: [Int], _ type: String, disposition: String? = nil) -> MessagePart {
        MessagePart(section: Section(section), contentType: type, disposition: disposition, size: 10)
    }

    @Test func retentionUsesInternalDateAndReportsAShortWindow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fresh = now.addingTimeInterval(-60)
        let expired = now.addingTimeInterval(-(CandidateVault.retention + 5))
        let decision = GmailCatchup.decide(
            stamps: [
                GmailEnvelopeStamp(uid: 4, internalDate: expired, sequence: 1),
                GmailEnvelopeStamp(uid: 9, internalDate: fresh, sequence: 2),
                GmailEnvelopeStamp(uid: 10, internalDate: nil, sequence: 3),
                GmailEnvelopeStamp(uid: 11, internalDate: now.addingTimeInterval(10 * 60), sequence: 4),
            ],
            messageCount: 8, limit: 4, now: now, retention: CandidateVault.retention,
            futureSkew: 120, handled: [])
        #expect(decision.fetchUIDs == [9])
        #expect(decision.expiredUIDs == [4])
        #expect(decision.undatedUIDs == [10])
        #expect(decision.futureUIDs == [11])
        #expect(!decision.fetchUIDs.contains(11))
        #expect(decision.receivedAt[9] == fresh)
        #expect(!decision.incomplete)

        let short = GmailCatchup.decide(
            stamps: [
                GmailEnvelopeStamp(uid: 8, internalDate: fresh, sequence: 5),
                GmailEnvelopeStamp(uid: 9, internalDate: now.addingTimeInterval(-10), sequence: 6),
            ],
            messageCount: 8, limit: 2, now: now, retention: CandidateVault.retention,
            futureSkew: 120, handled: [])
        #expect(short.fetchUIDs == [9, 8])
        #expect(short.incomplete)

        let covered = GmailCatchup.decide(
            stamps: [
                GmailEnvelopeStamp(uid: 4, internalDate: expired, sequence: 7),
                GmailEnvelopeStamp(uid: 9, internalDate: fresh, sequence: 8),
            ],
            messageCount: 8, limit: 2, now: now, retention: CandidateVault.retention,
            futureSkew: 120, handled: [9])
        #expect(covered.fetchUIDs.isEmpty)
        #expect(covered.expiredUIDs == [4])
        #expect(!covered.incomplete)
    }

    @Test func terminalErrorsStaySanitized() {
        let leaked = ["AUTHENTICATIONFAILED", "NO [", "Subject:", "LOGIN", "\r\n", "abcdefgh"]
        for error in [
            GmailIMAPError.authenticationRejected, .idleUnavailable, .mailboxNotReadOnly,
        ] {
            let text = [
                (error as LocalizedError).errorDescription,
                (error as LocalizedError).failureReason,
                error.localizedDescription,
            ].compactMap { $0 }.joined(separator: "\n")
            #expect(!text.isEmpty)
            for token in leaked {
                #expect(!text.contains(token))
            }
        }
    }

    @Test func onlyKnownBodyLimitsAreSkippable() {
        struct Ordinary: Error {}
        struct ExceededMaximumBodySizeError: Error {}
        struct Wrapped: Error { var parserError: Error }
        #expect(!GmailFetchLimit.isBound(Ordinary()))
        #expect(GmailFetchLimit.isBound(Wrapped(parserError: ExceededMaximumBodySizeError())))
        #expect(!GmailFetchLimit.isBound(Wrapped(parserError: Ordinary())))
    }

    @Test func swiftMailInfoLoggingIsDisabled() {
        _ = GmailIMAPFeed()
        let mail = Logger(label: "com.cocoanetics.SwiftMail.IMAPServer")
        let imap = Logger(label: "com.cocoanetics.SwiftIMAP")
        let other = Logger(label: "mail-code-filler")
        #expect(mail.handler is SwiftLogNoOpLogHandler)
        #expect(imap.handler is SwiftLogNoOpLogHandler)
        #expect(mail.logLevel == .critical)
        #expect(other.handler is StreamLogHandler)
        #expect(other.logLevel == .info)
        mail.error("AUTHENTICATIONFAILED Subject: gmail-log-canary")
        _ = GmailIMAPFeed()
    }

    @Test func mimePartsDoNotShareSignatureOrCodeContext() {
        let samples: [(plain: String, html: String, expected: [String])] = [
            ("Open the HTML version.\n--\nSignature", "<p>Your verification code is 246810</p>", ["246810"]),
            ("Your verification code is", "<p>123456 items in the catalog</p>", []),
        ]
        for sample in samples {
            let outcome = GmailMessageText.decode(
                subject: "Message", sender: "sample@example.test",
                parts: [
                    (GmailTextPart(mime: "text/plain"), Data(sample.plain.utf8)),
                    (GmailTextPart(mime: "text/html"), Data(sample.html.utf8)),
                ], maxBytes: 8_000)
            guard case .message(let mail) = outcome else {
                Issue.record("Body missing")
                continue
            }
            #expect(CodeDetector().codes(subject: mail.subject, bodies: mail.bodies) == sample.expected)
        }
    }

    @Test func standaloneCodeInItsOwnHTMLBlockIsDetected() {
        let html = """
            <p>您好!为确保账号安全，请使用以下验证码完成邮箱验证，验证码有效期为10分钟。</p>
            <div>771285</div>
            <p>如果您没有发起此操作，请忽略此邮件。</p>
            """
        let body = GmailMessageText.htmlToText(html)
        #expect(body.contains("\n771285\n"))
        #expect(CodeDetector().codes(subject: "用户验证码", body: body) == ["771285"])
    }

    @Test func normalizationCannotTruncateAnOversizedTokenIntoACode() {
        let text = "éééééééééé\nYour verification code is 12345678901234"
        let bytes = text.data(using: .isoLatin1)!
        let outcome = GmailMessageText.decode(
            subject: "Login", sender: "sample@example.test",
            parts: [(GmailTextPart(mime: "text/plain; charset=iso-8859-1"), bytes)],
            maxBytes: bytes.count)
        #expect(outcome == .notice(GmailNotice.oversized))
    }

    @Test func productionRenewalFitsInsideRetention() {
        let renewal = GmailIMAPConfiguration.gmail.idleRenewal
        #expect(renewal <= .seconds(5 * 60))
        #expect(renewal < .seconds(CandidateVault.retention))
        #expect(GmailIMAPConfiguration.gmail.livenessInterval <= .seconds(60))
    }

    @Test func productionEndpointKeepsCertificateValidation() {
        let gmail = GmailIMAPConfiguration.gmail
        #expect(gmail.host == "imap.gmail.com")
        #expect(gmail.port == 993)
        #expect(gmail.transportSecurity == .implicitTLS)
        #expect(gmail.retention == CandidateVault.retention)
        #expect(!gmail.backoff.isEmpty)
    }
}
