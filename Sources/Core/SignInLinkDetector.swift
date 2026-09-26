import Foundation

public struct SignInLink: Equatable, Sendable {
    public enum Purpose: Equatable, Sendable {
        case signIn
        case activation
        case verification
        case accountNotice

        public var actionLabel: String {
            switch self {
            case .signIn: return "打开登录链接"
            case .activation: return "打开激活链接"
            case .verification: return "打开验证链接"
            case .accountNotice: return "查看账号安全提醒"
            }
        }

        public var displayName: String {
            switch self {
            case .signIn: return "登录链接"
            case .activation: return "激活链接"
            case .verification: return "验证链接"
            case .accountNotice: return "账号安全提醒"
            }
        }
    }

    public let url: URL
    public let host: String
    public let registrableHost: String
    public let purpose: Purpose

    public init(url: URL, purpose: Purpose = .signIn) {
        self.url = url
        host = url.host ?? ""
        registrableHost = Self.registrableHost(host)
        self.purpose = purpose
    }

    private static let compoundSuffixes: Set<String> = [
        "ac.uk", "co.in", "co.jp", "co.nz", "co.uk", "com.au", "com.br", "com.cn",
        "com.hk", "com.mx", "com.sg", "com.tr", "com.tw", "com.za", "github.io",
        "appspot.com", "azurewebsites.net", "cloudfront.net", "herokuapp.com", "netlify.app",
        "pages.dev", "vercel.app", "workers.dev",
    ]

    private static func registrableHost(_ rawHost: String) -> String {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let labels = host.split(separator: ".")
        guard labels.count > 2, !host.contains(":"),
            !labels.allSatisfy({ UInt8($0) != nil })
        else { return host }
        let suffix = labels.suffix(2).joined(separator: ".")
        let count = compoundSuffixes.contains(suffix) ? 3 : 2
        return labels.suffix(count).joined(separator: ".")
    }
}

/// Finds one user-clickable sign-in URL without fetching tracking redirects.
public struct SignInLinkDetector: Sendable {
    private struct Reference {
        let href: String
        let text: String
        let context: String
    }

    private struct RankedLink {
        let link: SignInLink
        let score: Int
        let order: Int
    }

    private static let urlPattern = compile(#"(?i)https://[^\s<>"']+"#)
    private static let loginPattern = compile(
        #"(?i)(?<![A-Za-z])(?:sign[\s-]*in|log[\s-]*in|magic[\s-]*link)(?![A-Za-z])|登录|登入|登錄|确认登录|確認登入|登录链接|登入連結"#
    )
    private static let verificationPattern = compile(
        #"(?i)\b(?:verify|verifying|verification|confirm|confirming|confirmation)\s+(?:your\s+)?(?:e-?mail|mailbox|account)\b|\bverify\s+to\s+(?:keep|access|secure|protect|continue)\b|\b(?:e-?mail|account)\s+(?:verification|confirmation)\b|验证邮箱|驗證郵箱|验证电子邮件|确认电子邮件|確認電子郵件|确认邮箱|確認郵箱|邮箱验证|郵箱驗證|邮箱确认|郵箱確認"#
    )
    private static let activationPattern = compile(
        #"(?i)\b(?:activate|activated|activating|activation|complete\s+(?:your\s+)?registration|finish\s+(?:your\s+)?registration)\b|激活(?:您的|你的)?(?:账号|帳號|账户|帳戶)?|完成注册|完成註冊"#
    )
    private static let passwordResetPattern = compile(
        #"(?i)(?:password.{0,16}reset|reset.{0,16}password|forgot.{0,16}password|密码.{0,6}重置|重置.{0,6}密码|找回密码)"#
    )
    private static let accountNoticePattern = compile(
        #"(?i)\b(?:security\s+alert|new\s+sign[\s-]*in|(?:new|unknown|unrecognized)\s+device.{0,40}(?:sign[\s-]*in|signed\s+in|log[\s-]*in|logged\s+in)|unusual\s+sign[\s-]*in|suspicious\s+activity|check\s+activity|was\s+this\s+you|password\s+changed|(?:2fa|two[\s-]*factor(?:\s+authentication)?)\s+changed|new\s+ssh\s+key\s+added|security\s+notice|successful(?:ly)?\s+(?:log[\s-]*in|sign[\s-]*in|logged\s+in|signed\s+in)|(?:log[\s-]*in|sign[\s-]*in)\s+(?:alert|notification|notice)|new\s+log[\s-]*in|signed\s+in\s+(?:from|on|with|using))\b|安全警告|安全通知|异常登录|新设备登录|可疑活动|账号安全提醒|帳號安全提醒|登录提醒|登录通知|成功登录|登录成功"#
    )
    private static let actionPattern = compile(
        #"(?i)\b(?:continue|proceed|open|verify|confirm|access|check|review|click\s+here|use\s+this\s+link|was\s+this\s+you)\b|继续|前往|打开|验证|確認|确认|进入|查看活动"#
    )
    private static let excludedTextPattern = compile(
        #"(?i)\b(?:unsubscribe|manage\s+(?:email\s+)?preferences|privacy(?:\s+policy)?|help\s+center|support\s+center|documentation)\b|退订|取消订阅|隐私政策|隱私權|帮助中心|說明中心"#
    )
    private static let excludedPathPattern = compile(
        #"(?i)(?:unsubscribe|opt[-_]?out|preferences?|privacy|help|support|docs|terms)"#
    )
    private static let tokenURLHint = compile(#"(?i)^(?:access[_-]?)?token$"#)
    private static let oneTimeParameter = compile(
        #"(?i)(?:^|[_-])(?:token|code|key|ticket|otp|activation(?:code)?|verification(?:code)?|magic|nonce|sig(?:nature)?|secret|one[_-]?time)(?:$|[_-])"#
    )
    private static let bodySignInIntent = compile(
        #"(?i)\b(?:use|click|follow|open|tap|continue|finish|complete|enter)\b.{0,100}\b(?:sign(?:ing)?[\s-]*in|log[\s-]*in|magic[\s-]*link)\b|\b(?:sign[\s-]*in|log[\s-]*in)\b.{0,80}\b(?:with|using|via|through|by)\b.{0,24}\b(?:link|button|code)\b|\bsign[\s-]*in\b.{0,60}\b(?:to\s+(?:review|access|continue)|instead)\b"#
    )
    private static let imageExtensionPattern = compile(#"(?i)\.(?:png|jpe?g|gif|svg|webp|bmp|ico|avif)$"#)
    private static let socialHosts: Set<String> = [
        "facebook.com", "instagram.com", "linkedin.com", "tiktok.com", "twitter.com",
        "x.com", "youtube.com", "youtu.be",
    ]

    public init() {}

    public func detect(subject: String, bodies: [String], links: [MailLink] = []) -> SignInLink? {
        let cleanBodies = bodies.map { MailCodeText.unquotedText(MailCodeText.normalize($0)) }
        let bodyText = cleanBodies.joined(separator: "\n")
        let subjectPurpose = Self.purpose(in: subject)
        let bodyPurpose = Self.bodyPurpose(in: bodyText)
        let emailPurpose = subjectPurpose ?? bodyPurpose
        var references = links.map {
            Reference(href: $0.href, text: $0.text, context: $0.context)
        }
        for body in cleanBodies {
            for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
                let context = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                let range = NSRange(context.startIndex..., in: context)
                for match in Self.urlPattern.matches(in: context, range: range) {
                    guard let urlRange = Range(match.range, in: context) else { continue }
                    references.append(
                        Reference(
                            href: Self.trimURL(String(context[urlRange])), text: context, context: context))
                }
            }
        }

        let isPasswordReset = Self.matches(
            Self.passwordResetPattern, in: subject + "\n" + bodyText)
        if isPasswordReset { return nil }
        var seen = Set<String>()
        var eligible: [(reference: Reference, url: URL, target: URL)] = []
        for reference in references {
            guard let url = Self.secureURL(reference.href),
                let target = Self.judgmentTarget(for: url),
                !Self.isExcluded(target, text: reference.text + "\n" + reference.context),
                Self.hasOneTimeMaterial(target),
                seen.insert(url.absoluteString).inserted
            else { continue }
            eligible.append((reference, url, target))
        }
        let hasSemanticTarget = eligible.contains { _, _, target in
            Self.purpose(from: target) != nil
        }
        guard emailPurpose != nil || hasSemanticTarget else { return nil }

        // Incidental account words and per-reader article tokens are not credentials.
        // With no subject or URL purpose, only an explicit sign-in token supports
        // the weaker intent expressed in the body.
        if subjectPurpose == nil && !hasSemanticTarget {
            guard emailPurpose == .signIn, links.count <= 12 else { return nil }
            eligible = eligible.filter {
                Self.hasExplicitOneTimeParameter($0.target)
                    || Self.hasFragmentOneTimeMaterial($0.target)
            }
            guard !eligible.isEmpty else { return nil }
        }

        var ranked: [RankedLink] = []
        for (order, candidate) in eligible.enumerated() {
            let reference = candidate.reference
            let url = candidate.url
            let target = candidate.target
            let referenceText = reference.text + "\n" + reference.context
            let referencePurpose = Self.purpose(in: referenceText)
            let urlPurpose = Self.purpose(from: target)
            let action =
                Self.matches(Self.actionPattern, in: reference.text)
                || Self.matches(Self.actionPattern, in: reference.context)
            let tokenHint = Self.hasTokenHint(target)

            let score: Int
            if referencePurpose != nil {
                score = 100
            } else if urlPurpose != nil {
                score = 90
            } else if subjectPurpose != nil && action {
                score = tokenHint ? 80 : 70
            } else if bodyPurpose != nil && action {
                score = tokenHint ? 70 : 60
            } else if !isPasswordReset && emailPurpose != nil && eligible.count == 1 {
                score = 40
            } else {
                continue
            }
            let purpose =
                emailPurpose == .accountNotice
                ? .accountNotice : (referencePurpose ?? urlPurpose ?? emailPurpose ?? .signIn)
            ranked.append(
                RankedLink(link: SignInLink(url: url, purpose: purpose), score: score, order: order))
        }
        return ranked.max { lhs, rhs in
            lhs.score == rhs.score ? lhs.order > rhs.order : lhs.score < rhs.score
        }?.link
    }

    private static func purpose(in text: String) -> SignInLink.Purpose? {
        if matches(accountNoticePattern, in: text) { return .accountNotice }
        if matches(activationPattern, in: text) { return .activation }
        if matches(verificationPattern, in: text) { return .verification }
        if matches(loginPattern, in: text) { return .signIn }
        return nil
    }

    private static func bodyPurpose(in text: String) -> SignInLink.Purpose? {
        if matches(accountNoticePattern, in: text) { return .accountNotice }
        if matches(activationPattern, in: text) { return .activation }
        if matches(verificationPattern, in: text) { return .verification }
        if matches(bodySignInIntent, in: text) { return .signIn }
        return nil
    }

    private static func purpose(from url: URL) -> SignInLink.Purpose? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let separators = CharacterSet(charactersIn: "/._-?&=")
        var terms = url.path.lowercased().components(separatedBy: separators).filter { !$0.isEmpty }
        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
            terms += name.components(separatedBy: separators).filter { !$0.isEmpty }
            if !matches(tokenURLHint, in: name), let value = item.value {
                terms += value.lowercased().components(separatedBy: separators).filter { !$0.isEmpty }
            }
        }
        let accountTerms = ["account", "user", "registration"]
        let emailTerms = ["email", "mailbox", "account"]
        if terms.contains(where: { ["activate", "activated", "activation", "activationcode"].contains($0) })
            && (terms.contains(where: accountTerms.contains) || terms.contains("activationcode"))
        {
            return .activation
        }
        if terms.contains(where: {
            ["verify", "verification", "confirm", "confirmation", "verificationcode"].contains($0)
        }) && (terms.contains(where: emailTerms.contains) || terms.contains("verificationcode")) {
            return .verification
        }
        return nil
    }

    private static func hasTokenHint(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let separators = CharacterSet(charactersIn: "/._-?&=")
        let pathTerms = url.path.lowercased().components(separatedBy: separators)
        let queryTerms = (components.queryItems ?? []).flatMap {
            $0.name.lowercased().components(separatedBy: separators)
        }
        return (pathTerms + queryTerms).contains("token")
    }

    private static func hasOneTimeMaterial(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        if (components.queryItems ?? []).contains(where: { item in
            guard let value = item.value, !value.isEmpty else { return false }
            if matches(oneTimeParameter, in: item.name) { return true }
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !["campaign", "source", "medium", "ref", "upn"].contains(name)
                && isHighEntropySegment(value)
        }) {
            return true
        }
        if url.path.split(separator: "/").contains(where: { isHighEntropySegment(String($0)) }) {
            return true
        }
        // Some services keep the token client-side, e.g. https://claude.ai/magic-link#<token>:<email>.
        return hasFragmentOneTimeMaterial(url)
    }

    private static func hasExplicitOneTimeParameter(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return (components.queryItems ?? []).contains {
            guard let value = $0.value, !value.isEmpty else { return false }
            return matches(oneTimeParameter, in: $0.name)
        }
    }

    private static func hasFragmentOneTimeMaterial(_ url: URL) -> Bool {
        guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment else {
            return false
        }
        return fragment.split(whereSeparator: { ":&=".contains($0) })
            .contains { isHighEntropySegment(String($0)) }
    }

    private static func isHighEntropySegment(_ raw: String) -> Bool {
        let segment = raw.removingPercentEncoding ?? raw
        guard segment.count >= 20, segment.count <= 512,
            segment.unicodeScalars.allSatisfy({ CharacterSet.urlPathAllowed.contains($0) })
        else { return false }
        let letters = segment.filter(\.isLetter).count
        let digits = segment.filter(\.isNumber).count
        let unique = Set(segment).count
        guard letters >= 6, digits >= 2, unique >= 10 else { return false }
        // Readable slugs such as "educational-2012-02-25-en" split into pure words and numbers;
        // real tokens mix letters and digits inside one run.
        let runs = segment.split(whereSeparator: { "-_.~".contains($0) })
        return runs.contains { run in
            run.count >= 6 && run.contains(where: \.isLetter) && run.contains(where: \.isNumber)
        }
    }

    /// Known trackers are only evidence of the target they expose. Their own IDs,
    /// signatures and opaque paths are never treated as sign-in credentials.
    private static func judgmentTarget(for url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let host = components.host?.lowercased()
        else { return nil }
        let isSES = host == "awstrack.me" || host.hasSuffix(".awstrack.me")
        let isTracker =
            isSES
            || host == "ct.sendgrid.net" || host.hasSuffix(".ct.sendgrid.net")
            || host == "list-manage.com" || host.hasSuffix(".list-manage.com")
            || host == "mailgun.org" || host.hasSuffix(".mailgun.org")
            || host == "mailgun.net" || host.hasSuffix(".mailgun.net")
            || host == "click.pstmrk.it"
            || host == "track.pstmrk.it"
            || host == "hubspotlinks.com" || host.hasSuffix(".hubspotlinks.com")
            || host == "hubspotemail.net" || host.hasSuffix(".hubspotemail.net")
            || host == "braze.com" || host.hasSuffix(".braze.com")
            || host == "braze.eu" || host.hasSuffix(".braze.eu")
            || host == "customeriomail.com" || host.hasSuffix(".customeriomail.com")
        guard isTracker else { return url }

        let pathParts = components.percentEncodedPath.split(separator: "/")
        if isSES, let marker = pathParts.first?.uppercased(),
            ["L0", "CL0"].contains(marker), pathParts.count >= 2,
            let decoded = String(pathParts[1]).removingPercentEncoding,
            let target = secureURL(decoded)
        {
            return target
        }
        if isSES, pathParts.first?.uppercased() == "CL1", pathParts.count >= 3,
            let decoded = String(pathParts[2]).removingPercentEncoding,
            let target = secureURL(decoded)
        {
            return target
        }
        for item in components.queryItems ?? []
        where
            ["url", "target", "destination", "redirect", "redirect_url", "u"].contains(item.name.lowercased())
        {
            if let value = item.value, let target = secureURL(value) { return target }
        }
        for part in pathParts {
            if let decoded = String(part).removingPercentEncoding,
                let target = secureURL(decoded)
            {
                return target
            }
        }
        return nil
    }

    private static func secureURL(_ raw: String) -> URL? {
        let href = trimURL(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !href.isEmpty, href.utf8.count <= 8_192,
            let components = URLComponents(string: href), components.scheme?.lowercased() == "https",
            let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
            let url = components.url, url.absoluteString.utf8.count <= 8_192
        else { return nil }
        return url
    }

    private static func isExcluded(_ url: URL, text: String) -> Bool {
        let host = (url.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let path = url.path
        if matches(excludedTextPattern, in: text) || matches(excludedPathPattern, in: path)
            || matches(imageExtensionPattern, in: path)
        {
            return true
        }
        if host.hasPrefix("pixel.") || path.localizedCaseInsensitiveContains("/pixel")
            || path.localizedCaseInsensitiveContains("/open.gif")
        {
            return true
        }
        return socialHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    private static func trimURL(_ raw: String) -> String {
        var value = raw
        let punctuation = CharacterSet(charactersIn: ".,;:!?，。；：！？…\"'”’»")
        while let last = value.unicodeScalars.last, punctuation.contains(last) {
            value.unicodeScalars.removeLast()
        }
        while let last = value.last, [")", "]", "}"].contains(String(last)) {
            let opening = [")": "(", "]": "[", "}": "{"][String(last)]!
            let closings = value.filter { $0 == last }.count
            let openings = value.filter { String($0) == opening }.count
            if closings > openings {
                value.removeLast()
            } else {
                break
            }
        }
        return value
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func compile(_ pattern: String) -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: pattern) } catch {
            fatalError("Invalid sign-in link pattern: \(error)")
        }
    }
}
