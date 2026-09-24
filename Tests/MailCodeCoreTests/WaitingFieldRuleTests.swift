import Testing

@testable import MailCodeCore

struct WaitingFieldRuleTests {
    @Test func explicitLabelsMatch() {
        for label in ["验证码", "驗證碼", "Verification code", "One-time code", "OTP", "2FA code"] {
            #expect(WaitingFieldRule.matches(role: "AXTextField", subrole: nil, labels: [label]))
        }
    }

    @Test func genericAndSecureFieldsDoNotTrigger() {
        #expect(
            !WaitingFieldRule.matches(role: "AXTextField", subrole: nil, labels: ["Email", "Search", "Code"]))
        #expect(
            !WaitingFieldRule.matches(role: "AXSecureTextField", subrole: nil, labels: ["Verification code"]))
        #expect(!WaitingFieldRule.matches(role: "AXTextField", subrole: "AXSecureTextField", labels: ["OTP"]))
        #expect(!WaitingFieldRule.matches(role: "AXTextArea", subrole: nil, labels: ["OTP"]))
    }

    @Test func optionalPageGateRequiresBothSignals() {
        #expect(
            !WaitingFieldRule.matches(
                role: "AXTextField", subrole: nil, labels: ["OTP"], requireAuthPage: true))
        #expect(
            WaitingFieldRule.matches(
                role: "AXTextField", subrole: nil, labels: ["OTP"],
                looksLikeAuthPage: true, requireAuthPage: true))
        #expect(
            !WaitingFieldRule.matches(
                role: "AXTextField", subrole: nil, labels: ["Email"],
                looksLikeAuthPage: true, requireAuthPage: true))
    }
}
