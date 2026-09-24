import Foundation
import Testing

@testable import MailCodeCore

struct SignInLinkDetectorTests {
    let detector = SignInLinkDetector()

    @Test func detectsCommonMagicLinkTemplatesAndShowsRegistrableHost() throws {
        let claude = try #require(
            detector.detect(
                subject: "Sign in to Claude",
                bodies: ["Use the secure link below to sign in to Claude."],
                links: [
                    MailLink(
                        href: "https://auth.claude.ai/v1/authorize?token=secret",
                        text: "Continue to Claude", context: "Sign in to Claude")
                ]))
        #expect(claude.host == "auth.claude.ai")
        #expect(claude.registrableHost == "claude.ai")

        let slack = try #require(
            detector.detect(
                subject: "Your Slack sign-in link",
                bodies: ["This link signs you in."],
                links: [
                    MailLink(
                        href: "https://slack.com/magic-login?token=secret", text: "Sign in to Slack")
                ]))
        #expect(slack.host == "slack.com")

        let notion = try #require(
            detector.detect(
                subject: "验证邮箱并登录 Notion",
                bodies: ["请使用以下链接验证邮箱并登录。"],
                links: [
                    MailLink(
                        href: "https://www.notion.so/verify?token=secret", text: "验证邮箱并登录")
                ]))
        #expect(notion.registrableHost == "notion.so")

        let vercel = try #require(
            detector.detect(
                subject: "Sign in to Vercel",
                bodies: ["Sign in to continue."],
                links: [
                    MailLink(
                        href: "https://vercel.com/api/login?token=secret", text: "Continue",
                        context: "Sign in to Vercel")
                ]))
        #expect(vercel.registrableHost == "vercel.com")
    }

    @Test func keepsTrackingRedirectRawAndChoosesTheSemanticallyMatchedAnchor() throws {
        let rawTrackingURL = "https://click.mail.example.test/c/9?token=a%2Fb"
        let candidate = try #require(
            detector.detect(
                subject: "Weekly account update",
                bodies: ["Sign in to your account to review this update."],
                links: [
                    MailLink(
                        href: "https://help.example.test/account", text: "Help",
                        context: "Visit the help center"),
                    MailLink(
                        href: "https://example.test/unsubscribe", text: "Unsubscribe",
                        context: "Manage email preferences"),
                    MailLink(
                        href: rawTrackingURL, text: "Continue",
                        context: "Sign in to your account"),
                ]))
        #expect(candidate.url.absoluteString == rawTrackingURL)
        #expect(candidate.host == "click.mail.example.test")
    }

    @Test func newslettersAndPasswordResetMessagesDoNotBecomeLoginLinksByDefault() {
        #expect(
            detector.detect(
                subject: "Your weekly product digest",
                bodies: ["Five stories selected for you. Read more in this issue."],
                links: [
                    MailLink(href: "https://news.example.test/story/1", text: "Read more"),
                    MailLink(href: "https://news.example.test/story/2", text: "Read more"),
                    MailLink(href: "https://news.example.test/preferences", text: "Preferences"),
                ]) == nil)

        #expect(
            detector.detect(
                subject: "Reset your password",
                bodies: ["Use the button to choose a new password."],
                links: [
                    MailLink(
                        href: "https://accounts.example.test/password-reset?token=secret",
                        text: "Reset password", context: "Reset your password")
                ]) == nil)
    }

    @Test func passwordResetMailCannotBecomeALinkCandidate() {
        #expect(
            detector.detect(
                subject: "Reset your password",
                bodies: ["If you do not need a reset, sign in instead."],
                links: [
                    MailLink(
                        href: "https://accounts.example.test/login/magic?token=secret",
                        text: "Sign in instead")
                ]) == nil)
    }

    @Test func accountActivationAndEmailVerificationLinksCarryTheirPurpose() throws {
        let activation = try #require(
            detector.detect(
                subject: "康明斯 账户激活通知",
                bodies: ["您的账号已经生成，请在30分钟内点击 激活。"],
                links: [
                    MailLink(
                        href:
                            "https://careersite.tupu360.com/cummins/user/activate?email=person%40example.test&activationCode=secret",
                        text: "激活", context: "请在30分钟内点击 激活")
                ]))
        #expect(activation.host == "careersite.tupu360.com")
        #expect(activation.purpose == .activation)
        #expect(activation.purpose.actionLabel == "打开激活链接")

        let verification = try #require(
            detector.detect(
                subject: "Verify your email",
                bodies: ["Complete registration to continue."],
                links: [
                    MailLink(
                        href: "https://accounts.example.test/confirm-email?token=secret",
                        text: "Confirm your email")
                ]))
        #expect(verification.purpose == .verification)
        #expect(verification.purpose.actionLabel == "打开验证链接")
    }

    @Test func activationAndVerificationURLHintsWorkButGenericTokenNeedsMailSemantics() throws {
        let activation = try #require(
            detector.detect(
                subject: "Account notice", bodies: [],
                links: [
                    MailLink(
                        href:
                            "https://example.test/user/activate?email=person%40example.test&activationCode=secret",
                        text: "Continue")
                ]))
        #expect(activation.purpose == .activation)

        let verification = try #require(
            detector.detect(
                subject: "Account notice", bodies: [],
                links: [
                    MailLink(href: "https://example.test/confirm-email?token=secret", text: "Continue")
                ]))
        #expect(verification.purpose == .verification)

        #expect(
            detector.detect(
                subject: "Account notice", bodies: [],
                links: [MailLink(href: "https://example.test/continue?token=secret", text: "Continue")])
                == nil)
    }

    @Test func activationMailStillRejectsFooterLinks() throws {
        let candidate = try #require(
            detector.detect(
                subject: "Activate your account",
                bodies: ["Click the activation link to complete registration."],
                links: [
                    MailLink(href: "https://example.test/activate?token=secret", text: "Activate account"),
                    MailLink(href: "https://example.test/help", text: "Help center"),
                    MailLink(href: "https://example.test/privacy", text: "Privacy policy"),
                    MailLink(href: "https://example.test/unsubscribe", text: "Unsubscribe"),
                ]))
        #expect(candidate.url.path == "/activate")
        #expect(candidate.purpose == .activation)
    }

    @Test func rejectsNonHTTPSFooterHelpSocialAndImageTargets() {
        let rejected = [
            MailLink(href: "http://accounts.example.test/login", text: "Sign in"),
            MailLink(href: "mailto:help@example.test", text: "Sign in"),
            MailLink(
                href: "https://accounts.example.test/unsubscribe", text: "Continue",
                context: "Sign in to your account"),
            MailLink(
                href: "https://example.test/privacy", text: "Privacy policy",
                context: "Sign in to your account"),
            MailLink(
                href: "https://example.test/help", text: "Help center",
                context: "Sign in to your account"),
            MailLink(
                href: "https://linkedin.com/company/example", text: "Sign in",
                context: "Sign in to your account"),
            MailLink(
                href: "https://cdn.example.test/pixel.gif", text: "Sign in",
                context: "Sign in to your account"),
        ]
        #expect(
            detector.detect(
                subject: "Sign in to your account",
                bodies: ["Use the sign-in link below."], links: rejected) == nil)
    }

    @Test func quotedURLsAreIgnoredAndOnlyOneCandidateIsReturned() throws {
        #expect(
            detector.detect(
                subject: "Reply",
                bodies: [
                    "Thanks\n> Sign in to the old account: https://old.example.test/login?token=old"
                ]) == nil)

        let candidate = try #require(
            detector.detect(
                subject: "Sign in to example",
                bodies: ["Choose either secure sign-in link."],
                links: [
                    MailLink(
                        href: "https://first.example.test/login?token=one", text: "Sign in"),
                    MailLink(
                        href: "https://second.example.test/login?token=two", text: "Sign in"),
                ]))
        #expect(candidate.host == "first.example.test")
    }

    @Test func sesTrackingUsesRealTargetButKeepsTheClickableURL() throws {
        let wrapped =
            "https://abc.r.us-east-1.awstrack.me/L0/https%3A%2F%2Faccounts.example.test%2Flogin%2Fmagic%3Ftoken%3Dfixture-value/1/opaque-id/opaque-signature"
        let candidate = try #require(
            detector.detect(
                subject: "Sign in to your account",
                bodies: ["Use this link to sign in."],
                links: [MailLink(href: wrapped, text: "Sign in")]))
        #expect(candidate.url.absoluteString == wrapped)
        #expect(candidate.host == "abc.r.us-east-1.awstrack.me")

        let home =
            "https://abc.r.us-east-1.awstrack.me/L0/https%3A%2F%2Fexample.test%2F/1/opaque-id/opaque-signature"
        #expect(
            detector.detect(
                subject: "Sign in to your account", bodies: ["Use this link to sign in."],
                links: [MailLink(href: home, text: "Sign in")]) == nil)
    }

    @Test func opaqueTrackerIDsNeverCountAsOneTimeMaterial() {
        let wrappers = [
            "https://u12345.ct.sendgrid.net/ls/click?upn=Opaque8hP4jK2mL9nQ7rS5tV",
            "https://example.list-manage.com/track/click?u=Opaque8hP4jK2mL9nQ7rS5tV&id=123",
            "https://track.mailgun.org/c/Opaque8hP4jK2mL9nQ7rS5tV",
            "https://click.pstmrk.it/2s/example.test/Opaque8hP4jK2mL9nQ7rS5tV",
            "https://links.hubspotlinks.com/e1t/c/Opaque8hP4jK2mL9nQ7rS5tV",
            "https://links.braze.com/c/Opaque8hP4jK2mL9nQ7rS5tV",
            "https://e.customeriomail.com/e/c/Opaque8hP4jK2mL9nQ7rS5tV",
        ]
        for wrapper in wrappers {
            #expect(
                detector.detect(
                    subject: "Sign in to your account", bodies: ["Use this link to sign in."],
                    links: [MailLink(href: wrapper, text: "Sign in")]) == nil)
        }
    }

    @Test func cancellationFooterCannotSupplyMailIntentEvenWithAToken() {
        #expect(
            detector.detect(
                subject: "Cancellation Request Confirmation",
                bodies: [
                    "We received your cancellation request. The service ends at the end of this billing period. Log in to your account."
                ],
                links: [
                    MailLink(
                        href: "https://example.test/login?token=fixture-value", text: "Log in to your account"
                    )
                ]) == nil)
    }

    @Test func orderConfirmationIsNotAccountVerification() {
        #expect(
            detector.detect(
                subject: "Order confirmation", bodies: ["Confirm your order below."],
                links: [
                    MailLink(
                        href: "https://shop.example.test/confirm/order?token=fixture-value",
                        text: "Confirm order")
                ]) == nil)
    }

    @Test func securityAlertsKeepTheirOwnPurpose() throws {
        let alerts: [(subject: String, body: String, href: String, text: String)] = [
            (
                "Security alert", "New sign-in to your Google Account. Check activity.",
                "https://myaccount.google.com/notifications?anexp=A8bC4dE6fG2hJ9kL3mN7pQ5r&authuser=0",
                "Check activity"
            ),
            (
                "Unusual sign-in activity", "We noticed unusual sign-in activity on your Microsoft account.",
                "https://account.live.com/Activity?ticket=fixture-value", "Review activity"
            ),
            (
                "New SSH key added", "A new SSH key was added to your GitHub account.",
                "https://github.com/settings/ssh?token=fixture-value", "Review your account"
            ),
        ]
        for alert in alerts {
            let link = try #require(
                detector.detect(
                    subject: alert.subject, bodies: [alert.body],
                    links: [MailLink(href: alert.href, text: alert.text)]))
            #expect(link.purpose == .accountNotice)
            #expect(link.purpose.actionLabel == "查看账号安全提醒")
        }
    }
}
