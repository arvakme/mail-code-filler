import Foundation

/// Uses labels only. Never pass an input value, selection, URL, or page text here.
public enum WaitingFieldRule {
    public static func matches(
        role: String?, subrole: String?, labels: [String],
        looksLikeAuthPage: Bool = false, requireAuthPage: Bool = false
    ) -> Bool {
        guard role == "AXTextField", subrole != "AXSecureTextField" else { return false }
        guard !requireAuthPage || looksLikeAuthPage else { return false }
        return labels.contains { label in
            let normalized = label.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if ["验证码", "驗證碼", "認證碼", "动态码", "動態碼", "一次性密码", "一次性密碼"].contains(where: normalized.contains) {
                return true
            }
            let words = normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            if words.contains("otp") || words.contains("2fa") { return true }
            let wordSet = Set(words)
            return wordSet.contains("code")
                && (wordSet.contains("verification") || wordSet.contains("verify")
                    || wordSet.contains("authentication") || wordSet.contains("security")
                    || wordSet.contains("one") && wordSet.contains("time"))
        }
    }
}
