import Foundation

/// Only redacted content is allowed in this model. It never stores message IDs or accounts.
public struct MissedDetectionSample: Codable, Equatable, Identifiable, Sendable {
    public struct Expected: Codable, Equatable, Sendable {
        public struct Link: Codable, Equatable, Sendable {
            public var url: String
            public var purpose: String

            public init(url: String, purpose: String) {
                self.url = url
                self.purpose = purpose
            }
        }

        public var codes: [String]
        public var links: [Link]

        public init(codes: [String] = [], links: [Link] = []) {
            self.codes = codes
            self.links = links
        }
    }

    public enum Body: Codable, Equatable, Sendable {
        case text(String)
        case parts(plain: String, html: String)

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else {
                let parts = try container.decode([String: String].self)
                self = .parts(plain: parts["plain"] ?? "", html: parts["html"] ?? "")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let text): try container.encode(text)
            case .parts(let plain, let html):
                try container.encode(["plain": plain, "html": html])
            }
        }

        public var texts: [String] {
            switch self {
            case .text(let text): return [text]
            case .parts(let plain, let html): return [plain, html]
            }
        }
    }

    public var id: UUID
    public var subject: String
    public var fromDomain: String
    public var mime: String
    public var body: Body
    public var expected: Expected
    public var notes: String
    public var source: String
    public var redactedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, subject, mime, body, expected, notes, source
        case fromDomain = "from-domain"
        case redactedAt = "redacted-at"
    }

    public init(
        id: UUID = UUID(), subject: String, fromDomain: String, mime: String,
        body: Body, expected: Expected = .init(), notes: String = "",
        source: String = "redacted-real", redactedAt: Date = Date()
    ) {
        self.id = id
        self.subject = subject
        self.fromDomain = fromDomain
        self.mime = mime
        self.body = body
        self.expected = expected
        self.notes = notes
        self.source = source
        self.redactedAt = redactedAt
    }
}

public enum MissedSampleValidationError: LocalizedError {
    case unreviewed
    case unsafeContent

    public var errorDescription: String? {
        switch self {
        case .unreviewed: return "请先检查并确认脱敏预览。"
        case .unsafeContent: return "样本仍含邮箱地址、原始链接或疑似验证码，请继续遮盖。"
        }
    }
}

/// A conservative final gate. Manual review remains required because names and addresses vary.
public enum MissedSampleValidator {
    private static let email = try! NSRegularExpression(
        pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, options: [.caseInsensitive])
    private static let rawURL = try! NSRegularExpression(
        pattern: #"https?://[^\s<>\"']+"#, options: [.caseInsensitive])
    private static let code = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])[A-Za-z0-9]{4,10}(?![A-Za-z0-9])"#)

    public static func validate(_ sample: MissedDetectionSample, reviewed: Bool) throws {
        guard reviewed else { throw MissedSampleValidationError.unreviewed }
        guard sample.source == "redacted-real",
            ["text/plain", "text/html", "multipart/alternative"].contains(sample.mime),
            sample.fromDomain.range(
                of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil
        else { throw MissedSampleValidationError.unsafeContent }
        let fields = [sample.subject, sample.notes] + sample.body.texts
        for field in fields {
            let range = NSRange(field.startIndex..., in: field)
            if email.firstMatch(in: field, range: range) != nil {
                throw MissedSampleValidationError.unsafeContent
            }
            for match in rawURL.matches(in: field, range: range) {
                guard let tokenRange = Range(match.range, in: field),
                    let url = URLComponents(string: String(field[tokenRange])),
                    url.scheme == "https", url.host == "example.invalid",
                    url.query == nil, url.fragment == nil
                else { throw MissedSampleValidationError.unsafeContent }
            }
            for match in code.matches(in: field, range: range) {
                guard let tokenRange = Range(match.range, in: field) else { continue }
                let token = field[tokenRange]
                if token.contains(where: \.isNumber)
                    && token.contains(where: { $0 != "0" && $0 != "X" && $0 != "x" })
                {
                    throw MissedSampleValidationError.unsafeContent
                }
            }
        }
        for expectedCode in sample.expected.codes {
            guard !expectedCode.isEmpty,
                expectedCode.allSatisfy({ $0 == "0" || $0 == "X" || $0 == "x" }),
                sample.body.texts.contains(where: { $0.contains(expectedCode) })
            else {
                throw MissedSampleValidationError.unsafeContent
            }
        }
        guard
            sample.expected.links.allSatisfy({ link in
                guard let url = URLComponents(string: link.url) else { return false }
                return url.scheme == "https" && url.host == "example.invalid"
                    && url.query == nil && url.fragment == nil
                    && ["signIn", "activation", "verification"].contains(link.purpose)
                    && sample.body.texts.contains(where: { $0.contains(link.url) })
            })
        else {
            throw MissedSampleValidationError.unsafeContent
        }
    }
}
