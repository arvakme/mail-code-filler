import Foundation

public struct MissedMailRedactor: Sendable {
    public init() {}

    public func makeDraft(from mail: ReceivedMail, now: Date = Date()) -> MissedDetectionSample {
        let domain = SenderIdentity(fromHeader: mail.sender).registrableDomain ?? "unknown.invalid"
        var bodies = mail.bodies.map(redact)
        let safeLinks = mail.links.map { link in
            redact(link.text) + " " + redact(link.href)
        }
        if !safeLinks.isEmpty {
            if bodies.isEmpty { bodies = [""] }
            bodies[bodies.count - 1] += "\n" + safeLinks.joined(separator: "\n")
        }
        let body: MissedDetectionSample.Body =
            bodies.count > 1
            ? .parts(plain: bodies.first ?? "", html: bodies.dropFirst().joined(separator: "\n"))
            : .text(bodies.first ?? "")
        return MissedDetectionSample(
            subject: redact(mail.subject), fromDomain: domain,
            mime: bodies.count > 1
                ? "multipart/alternative" : "text/plain", body: body, redactedAt: now)
    }

    public func markCode(_ placeholder: String, in sample: inout MissedDetectionSample) {
        guard sample.body.texts.contains(where: { $0.contains(placeholder) }) else { return }
        if !sample.expected.codes.contains(placeholder) {
            sample.expected.codes.append(placeholder)
        }
    }

    public func markLink(_ url: String, purpose: String, in sample: inout MissedDetectionSample) {
        guard let safeURL = URLComponents(string: url), safeURL.host == "example.invalid",
            sample.body.texts.contains(where: { $0.contains(url) })
        else {
            return
        }
        let link = MissedDetectionSample.Expected.Link(url: url, purpose: purpose)
        if !sample.expected.links.contains(link) { sample.expected.links.append(link) }
    }

    public func redact(_ raw: String) -> String {
        var result = raw
        // Replace URLs first so later token masking cannot break URL structure.
        result = replacing(
            in: result, pattern: #"https?://[^\s<>"']+"#, options: [.caseInsensitive]
        ) { matched in
            safeURL(matched)
        }
        result = replacing(
            in: result,
            pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            options: [.caseInsensitive]
        ) { _ in "[email]" }
        result = replacing(
            in: result, pattern: #"(?<!\d)(?:\+?\d[\d\s()-]{8,}\d)(?!\d)"#
        ) { _ in "[phone]" }
        result = replacing(
            in: result, pattern: #"(?<![A-Za-z0-9])[A-Za-z0-9]{4,10}(?![A-Za-z0-9])"#
        ) { matched in
            guard matched.contains(where: \.isNumber) else { return matched }
            return String(matched.map { $0.isNumber ? "0" : ($0.isUppercase ? "X" : "x") })
        }
        return result
    }

    private func safeURL(_ raw: String) -> String {
        guard let components = URLComponents(string: raw), components.scheme == "https" else {
            return "https://example.invalid/"
        }
        let allowed = Set([
            "login", "log-in", "signin", "sign-in", "verify", "verification",
            "activate", "activation", "confirm", "confirmation",
        ])
        let path = components.path.split(separator: "/")
            .map { allowed.contains($0.lowercased()) ? String($0).lowercased() : "redacted" }
            .joined(separator: "/")
        return "https://example.invalid/" + path
    }

    private func replacing(
        in text: String, pattern: String, options: NSRegularExpression.Options = [],
        transform: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(String(result[range])))
        }
        return result
    }
}
