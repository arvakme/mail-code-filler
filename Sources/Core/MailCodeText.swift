import Foundation

enum MailCodeText {
    /// HTML-to-text leaves NBSP or ideographic spaces inside labels, zero-width chars
    /// between OTP digits, and CRLF. Fold those before quote trimming.
    static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{3000}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
    }

    static func unquotedText(_ text: String) -> String {
        var lines: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "--" || trimmed.hasPrefix("-----Original Message-----")
                || (trimmed.hasPrefix("On ") && trimmed.hasSuffix("wrote:"))
            {
                break
            }
            if !trimmed.hasPrefix(">") { lines.append(line) }
        }
        return lines.joined(separator: "\n")
    }

}
