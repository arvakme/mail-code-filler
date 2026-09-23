import Foundation

/// Accepts decoded plain text; MIME decoding and sender authentication belong to MailFeed.
public struct CodeDetector: Sendable {
    /// English labels must start at an ASCII letter boundary so "nonverification"
    /// cannot backtrack into "verification". Chinese labels stay adjacent to Han text.
    private static let englishCue =
        #"(?<![A-Za-z])(?:verification code|confirmation code|security code|sign[- ]in code|login code|one[- ]time (?:code|password|passcode)|authentication code|two[- ]factor code|2FA code|OTP|passcode)(?![A-Za-z])"#
    private static let chineseCue =
        #"验[ \t]?证[ \t]?码|驗[ \t]?證[ \t]?碼|校[ \t]?验[ \t]?码|校[ \t]?驗[ \t]?碼|确[ \t]?认[ \t]?码|確[ \t]?認[ \t]?碼|动[ \t]?态[ \t]?密[ \t]?码|動[ \t]?態[ \t]?密[ \t]?碼|动[ \t]?态[ \t]?码|動[ \t]?態[ \t]?碼|安[ \t]?全[ \t]?码|安[ \t]?全[ \t]?碼"#
    private static let cue = "(?:" + englishCue + "|" + chineseCue + ")"

    /// A standalone token is only accepted after a nearby, explicit OTP label or a
    /// strong subject. Transaction and contact labels in the same short context win.
    private static let standaloneCue = compile(
        #"(?<![A-Za-z])(?:verification[ \t-]+code|confirmation[ \t-]+code|security[ \t-]+code|sign[ \t-]+in[ \t-]+code|login[ \t-]+code|one[ \t-]+time(?:[ \t-]+(?:code|password|passcode))?|authentication[ \t-]+code|two[ \t-]+factor[ \t-]+code|2FA[ \t-]+code|OTP|passcode)(?![A-Za-z])|"#
            + chineseCue
    )
    private static let standaloneBlock = compile(
        #"(?<![A-Za-z])(?:order|invoice|shipment|tracking|amount|total|balance|phone|mobile|telephone|date|transaction)(?![A-Za-z])|订单|订单号|发票|快递|运单|金额|余额|电话|手机|日期|账单|转账"#
    )
    private static let standaloneToken = compile(
        #"^[ \t]*([A-Za-z0-9]{4,10}|[0-9]{3}[ \t-][0-9]{3}|[0-9]{4}[ \t-][0-9]{4}|[0-9](?:[ \t][0-9]){3,9})[ \t]*$"#
    )
    private static let compactDate = compile(
        #"^(?:19|20)[0-9]{6}$|^(?:0[1-9]|1[0-2])(?:0[1-9]|[12][0-9]|3[01])(?:19|20)[0-9]{2}$"#)

    /// 4–10 ASCII alphanumerics, or a single grouped run. Not searched by itself.
    private static let token =
        #"([0-9]{3}[ \t-][0-9]{3}|[0-9]{4}[ \t-][0-9]{4}|[0-9](?:[ \t][0-9]){3,9}|[A-Za-z0-9]{4,10})(?![A-Za-z0-9-]|[ \t]+[0-9])"#

    private static let englishWord = #"[A-Za-z][A-Za-z0-9'’-]*"#

    /// Brand words stay on the same line. The copula needs its own leading space:
    /// the brand quantifier would otherwise consume "is" and leave no gap.
    private static let sameLineBrand = "(?:[ \\t]+" + englishWord + "){1,5}"

    private static let forward = compile(
        cue + #"\s*(?:(?:is|为|為|是)\s*)?[:：=]?\s*"# + token
    )
    private static let forwardBrand = compile(
        cue + #"[ \t]+(?:for|to)"# + sameLineBrand
            + #"(?:[ \t]+(?:is|为|為|是)[ \t]*[:：=]?|[ \t]*[:：=])\s*"# + token
    )
    private static let reverse = compile(
        #"(?<![A-Za-z0-9-])"# + token
            + #"(?:\s+is your(?:[ \t]+"# + englishWord + #"){0,4}\s*"#
            + #"|\s*(?:是您的|是你的)\s*)"# + cue
    )
    /// The code follows the instruction's colon. Words before that colon stay on one line,
    /// so a later phone number is not consumed.
    private static let instruction = compile(
        #"(?:please[ \t]+)?(?:use|enter)[ \t]+(?:this|the[ \t]+following)[ \t]+code[ \t]+to[ \t]+"#
            + #"(?:sign[ \t-]?in|log[ \t-]?in|verify)(?:[ \t]+"# + englishWord
            + #"){0,5}[ \t]*[:：]\s*"# + token
    )
    /// "your code is" also appears in promo copy. Require a sign-in, verification,
    /// or security subject, and skip order or newsletter subjects.
    private static let yourCode = compile(
        #"(?<![A-Za-z])your[ \t]+code[ \t]+is\s*[:：=]?\s*"# + token
    )
    private static let subjectGate = compile(
        #"(?<![A-Za-z])(?:sign[ -]?in|log[ -]?in|verification|confirmation|security|OTP|passcode)(?![A-Za-z])|验证|驗證|校验|校驗|确认|確認|登录|登入|安全(?!性)"#
    )
    private static let subjectBlock = compile(
        #"(?<![A-Za-z])(?:newsletter|digest|weekly|unsubscribe|invoice|tracking|shipment|order)(?![A-Za-z])|订单|发票|快递|账单|促销|周报"#
    )

    public init() {}

    public func codes(subject: String, bodies: [String]) -> [String] {
        var seen: Set<String> = []
        return bodies.flatMap { codes(subject: subject, body: $0) }
            .filter { seen.insert($0).inserted }
    }

    public func codes(subject: String, body: String) -> [String] {
        let cleanSubject = MailCodeText.unquotedText(MailCodeText.normalize(subject))
        let cleanBody = MailCodeText.unquotedText(MailCodeText.normalize(body))
        let text = cleanSubject + "\n" + cleanBody
        let range = NSRange(text.startIndex..., in: text)
        var matches =
            Self.forward.matches(in: text, range: range)
            + Self.forwardBrand.matches(in: text, range: range)
            + Self.reverse.matches(in: text, range: range)
            + Self.instruction.matches(in: text, range: range)
        if allowsLooseCode(in: subject) {
            matches += Self.yourCode.matches(in: text, range: range)
        }

        var candidates: [(offset: Int, code: String)] = []
        for match in matches {
            guard let codeRange = Range(match.range(at: 1), in: text) else { continue }
            // Grouping separators are not part of the code. Case and leading zeros stay.
            let code = text[codeRange].filter { !$0.isWhitespace && $0 != "-" }
            guard (4...10).contains(code.count), code.contains(where: \.isNumber)
            else { continue }
            candidates.append((match.range(at: 1).location, code))
        }

        let bodyLines = cleanBody.components(separatedBy: "\n")
        let bodyOffset = cleanSubject.utf16.count + 1
        let subjectHasCue = Self.matches(Self.standaloneCue, in: cleanSubject)
        var offset = bodyOffset
        for (lineIndex, line) in bodyLines.enumerated() {
            let lineRange = NSRange(line.startIndex..., in: line)
            if let match = Self.standaloneToken.firstMatch(in: line, range: lineRange),
                let codeRange = Range(match.range(at: 1), in: line)
            {
                let code = line[codeRange].filter { !$0.isWhitespace && $0 != "-" }
                if Self.isStandaloneCode(
                    code, lineIndex: lineIndex, lines: bodyLines, subjectHasCue: subjectHasCue)
                {
                    candidates.append((offset + match.range(at: 1).location, code))
                }
            }
            offset += line.utf16.count + 1
        }

        candidates.sort { $0.offset < $1.offset }
        var seen: Set<String> = []
        return candidates.compactMap { seen.insert($0.code).inserted ? $0.code : nil }
    }

    private static func isStandaloneCode(
        _ code: String, lineIndex: Int, lines: [String], subjectHasCue: Bool
    ) -> Bool {
        guard (4...10).contains(code.count), code.contains(where: \.isNumber) else { return false }
        let digits = code.filter(\.isNumber)
        guard digits.count < 9,
            firstMatch(compactDate, in: digits) == nil,
            !(digits.count == 4 && Int(digits).map { (1900...2099).contains($0) } == true)
        else { return false }

        var preceding: [(index: Int, text: String)] = []
        var index = lineIndex - 1
        while index >= 0 && preceding.count < 3 {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { preceding.append((index, line)) }
            index -= 1
        }
        let cueIndex = preceding.first(where: { matches(standaloneCue, in: $0.text) })?.index
        guard let cueIndex = cueIndex ?? (subjectHasCue ? -1 : nil) else { return false }
        return !preceding.contains {
            $0.index > cueIndex && matches(standaloneBlock, in: $0.text)
        } && !(cueIndex >= 0 && matches(standaloneBlock, in: lines[cueIndex]))
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> Bool {
        firstMatch(regex, in: text) != nil
    }

    private func allowsLooseCode(in subject: String) -> Bool {
        let subject = MailCodeText.normalize(subject)
        let range = NSRange(subject.startIndex..., in: subject)
        return Self.subjectGate.firstMatch(in: subject, range: range) != nil
            && Self.subjectBlock.firstMatch(in: subject, range: range) == nil
    }

    private static func compile(_ pattern: String) -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: pattern, options: .caseInsensitive) } catch {
            fatalError("Invalid code pattern: \(error)")
        }
    }
}
