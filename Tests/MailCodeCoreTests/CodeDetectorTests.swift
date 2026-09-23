import Testing

@testable import MailCodeCore

struct CodeDetectorTests {
    struct Sample: Sendable, CustomTestStringConvertible {
        var subject: String
        var body: String
        var codes: [String]
        var testDescription: String { "mail fixture" }
    }

    private static let contextual: [Sample] = [
        Sample(subject: "Your verification code", body: "001234", codes: ["001234"]),
        Sample(subject: "登录", body: "您的验证码为：aB12cD。", codes: ["aB12cD"]),
        Sample(subject: "Sign in", body: "Your security code is 001 234", codes: ["001234"]),
        Sample(subject: "Sign in", body: "Your security code is 0012 3456", codes: ["00123456"]),
        Sample(subject: "Sign in", body: "Your security code is 123-456-7890", codes: []),
        Sample(subject: "Sign in", body: "Your security code is 123456 789012", codes: []),
        Sample(subject: "Login", body: "123456 is your verification code.", codes: ["123456"]),
        Sample(subject: "登录验证码：123456", body: "验证码：123456", codes: ["123456"]),
        Sample(subject: "登录", body: "验证码：123456\n动态码：654321", codes: ["123456", "654321"]),
        Sample(
            subject: "Invoice 123456", body: "Order number 123456. Phone: 1234567890. Total 1234.00",
            codes: []),
        Sample(
            subject: "Verification code expires", body: "Order 123456. Please request a new code.", codes: []),
        Sample(subject: "Login", body: "Verification code: 123456789012", codes: []),
        Sample(subject: "Reply", body: "> Verification code: 123456\nThank you", codes: []),
        Sample(
            subject: "Reply", body: "Thanks\nOn Monday someone wrote:\nVerification code: 123456", codes: []),
        Sample(subject: "Reply", body: "Thanks\n-- \nVerification code: 123456", codes: []),
    ]

    /// Synthetic phrasing distilled from public OTP templates. Not a private inbox.
    private static let separated: [Sample] = [
        Sample(subject: "Account", body: "Your verification code for Example is: 001234", codes: ["001234"]),
        Sample(subject: "Account", body: "Use this code to sign in:\n001234", codes: ["001234"]),
        Sample(subject: "Account", body: "123456 is your Example verification code", codes: ["123456"]),
        Sample(subject: "Sign in", body: "Your code is\n123456", codes: ["123456"]),
        Sample(subject: "Security", body: "Your code is\n001234", codes: ["001234"]),
        Sample(subject: "Login", body: "Sign-in code: ab12CD", codes: ["ab12CD"]),
        Sample(subject: "Login", body: "Enter the following code to verify:\nab12CD", codes: ["ab12CD"]),
        Sample(
            subject: "Login", body: "Please use this code to sign in to Example:\n001234", codes: ["001234"]),
        Sample(subject: "Sign in", body: "Your code is 123456\nOrder 654321 was shipped.", codes: ["123456"]),
        Sample(
            subject: "Sign in", body: "Your code is 123456\n-- \nVerification code: 654321", codes: ["123456"]
        ),
        Sample(
            subject: "Login",
            body: "Your verification code for Example is: 123456\n123456 is your Example verification code.",
            codes: ["123456"]
        ),
    ]

    private static let spaced: [Sample] = [
        Sample(subject: "登录", body: "验 证 码：\n001234", codes: ["001234"]),
        Sample(subject: "登录", body: "验证码：1 2 3 4 5 6", codes: ["123456"]),
        Sample(subject: "登录", body: "您的动态密码为：aB12cD。", codes: ["aB12cD"]),
        Sample(subject: "登录", body: "123456是您的验证码，请在5分钟内填写", codes: ["123456"]),
        Sample(subject: "登录", body: "验 证 码：123456\n动 态 码：654321", codes: ["123456", "654321"]),
        Sample(subject: "Login", body: "Your verification code is:\r\n001234", codes: ["001234"]),
        Sample(subject: "Sign in", body: "Your security code is 001\u{00A0}234", codes: ["001234"]),
        Sample(subject: "登录", body: "验\u{3000}证\u{3000}码：00\u{200B}1234", codes: ["001234"]),
    ]

    private static let looseRejections: [Sample] = [
        Sample(subject: "Security newsletter", body: "Your code is 123456", codes: []),
        Sample(subject: "Security", body: "Remember that 123456 is only an example.", codes: []),
        Sample(subject: "Sign in", body: "Your promo code is 123456", codes: []),
        Sample(subject: "Sign in", body: "The error code is 123456", codes: []),
        Sample(subject: "Invoice", body: "Your code is 123456", codes: []),
        Sample(subject: "Order verification", body: "Your code is 123456", codes: []),
        Sample(subject: "Weekly sign-in digest", body: "Your code is 123456", codes: []),
        Sample(subject: "Signing bonus", body: "Your code is 123456", codes: []),
        Sample(
            subject: "Account", body: "Your verification code for Example expires tomorrow. Order 123456.",
            codes: []),
    ]

    private static let unrelated: [Sample] = [
        Sample(subject: "Account", body: "Use this code to sign in. Phone: 1234567890", codes: []),
        Sample(subject: "Sign in", body: "Your code is 2024-09-22", codes: []),
        Sample(subject: "Sign in", body: "Your code is 123456789012", codes: []),
        Sample(subject: "Sign in", body: "Your code is ABCD", codes: []),
        Sample(subject: "Sign in", body: "> Your code is 123456\nThanks", codes: []),
        Sample(
            subject: "Reply", body: "Thanks\r\nOn Monday someone wrote:\r\nVerification code: 123456",
            codes: []),
        Sample(subject: "Your verification code", body: "Please ignore this note. 123456", codes: []),
        Sample(subject: "登录", body: "8888是您的订单尾号不是验证码", codes: []),
        Sample(subject: "Invoice", body: "Call 1 2 3 4 5 6 today", codes: []),
    ]

    private static let boundaries: [Sample] = [
        Sample(subject: "Account", body: "Your verification code for Example is 001234", codes: ["001234"]),
        Sample(subject: "Account", body: "123456 is your nonverification code", codes: []),
        Sample(subject: "Account", body: "Your nonverification code is 123456", codes: []),
    ]

    /// Public-template-shaped fixtures; no private inbox content is used.
    private static let realWorldFixtures: [Sample] = [
        Sample(
            subject: "用户验证码",
            body: "您好!为确保账号安全，请使用以下验证码完成邮箱验证，验证码有效期为10分钟。\n\n771285\n\n如果您没有发起此操作，请忽略此邮件。",
            codes: ["771285"]),
        Sample(
            subject: "阿里云账号验证",
            body: "为了完成安全验证，请输入验证码：\n483901\n该验证码 5 分钟内有效。",
            codes: ["483901"]),
        Sample(subject: "腾讯云动态验证码", body: "您的动态码\n194207\n请勿向他人透露。", codes: ["194207"]),
        Sample(subject: "飞书邮箱验证", body: "确认码\n682401\n此验证码 10 分钟内有效。", codes: ["682401"]),
        Sample(subject: "招聘系统账号安全", body: "校验码\n568329\n请完成本次邮箱验证。", codes: ["568329"]),
        Sample(
            subject: "GitHub device verification",
            body: "Your GitHub verification code is 614209. It expires in 10 minutes.",
            codes: ["614209"]),
        Sample(subject: "Microsoft account security code", body: "735 196", codes: ["735196"]),
        Sample(subject: "Apple ID 验证码", body: "609812", codes: ["609812"]),
        Sample(subject: "Steam sign-in code", body: "Your one-time code\nS2G4K", codes: ["S2G4K"]),
        Sample(subject: "Google verification", body: "您的 Google 验证码是：381726", codes: ["381726"]),
        Sample(subject: "Amazon sign-in", body: "One-time code: 924681", codes: ["924681"]),
        Sample(subject: "Slack security code", body: "Your security code\n518204", codes: ["518204"]),
        Sample(
            subject: "Login verification",
            body: "Your one-time code\nPlease keep it private.\nIt expires in five minutes.\n204681",
            codes: ["204681"]),
        Sample(subject: "Discord verification code", body: "Your code is 735849", codes: ["735849"]),
        Sample(subject: "Notion passcode", body: "Passcode\nQ7R2W9", codes: ["Q7R2W9"]),
        Sample(subject: "Zoom OTP", body: "OTP\n653240", codes: ["653240"]),
        Sample(subject: "校验码", body: "请使用安全码\n430917\n完成本次验证。", codes: ["430917"]),
        Sample(
            subject: "账户资金变动",
            body: "账户转入 50,000.00 元。\n可用余额\n12345678\n交易流水号 202609230001。",
            codes: []),
        Sample(
            subject: "订单确认",
            body: "订单号\n814209\n商品金额 2,480.00 元。",
            codes: []),
        Sample(
            subject: "Your verification code",
            body: "Registered phone number\n13800138000",
            codes: []),
        Sample(
            subject: "Your security code",
            body: "Renewal date\n20260923",
            codes: []),
    ]

    @Test(arguments: contextual)
    func detectsOnlyContextualCodes(_ sample: Sample) {
        #expect(CodeDetector().codes(subject: sample.subject, body: sample.body) == sample.codes)
    }

    @Test(arguments: separated)
    func detectsSeparatedOTPPhrases(_ sample: Sample) {
        #expect(CodeDetector().codes(subject: sample.subject, body: sample.body) == sample.codes)
    }

    @Test(arguments: spaced)
    func detectsSpacedAndWrappedCodes(_ sample: Sample) {
        #expect(CodeDetector().codes(subject: sample.subject, body: sample.body) == sample.codes)
    }

    @Test(arguments: looseRejections)
    func rejectsLooseCodeFalsePositives(_ sample: Sample) {
        #expect(CodeDetector().codes(subject: sample.subject, body: sample.body) == sample.codes)
    }

    @Test(arguments: unrelated)
    func rejectsUnrelatedNumbers(_ sample: Sample) {
        #expect(CodeDetector().codes(subject: sample.subject, body: sample.body) == sample.codes)
    }

    @Test(arguments: boundaries)
    func detectsUncolonedBrandCopulaAndCueBoundary(_ sample: Sample) {
        #expect(CodeDetector().codes(subject: sample.subject, body: sample.body) == sample.codes)
    }

    @Test(arguments: realWorldFixtures)
    func detectsRealWorldShapedTemplatesWithoutDatesOrAmounts(_ sample: Sample) {
        #expect(CodeDetector().codes(subject: sample.subject, body: sample.body) == sample.codes)
    }
}
