import CoreFoundation
import Foundation
import MailCodeCore
import SwiftMail

struct GmailTextPart: Equatable, Sendable {
    var mime: String
    var transferEncoding: String?
}

struct GmailDecodedMail: Equatable, Sendable {
    var subject: String
    var sender: String
    var bodies: [String]
    var links: [MailLink]
    var hasUndecodablePart: Bool
}

enum GmailDecodeOutcome: Equatable, Sendable {
    case message(GmailDecodedMail)
    case notice(String)
}

enum GmailMessageText {
    private static let chineseLegacyEncoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringConvertIANACharSetNameToEncoding("GB18030" as CFString)))

    /// At most the first plain part and the first HTML part. `Message.bodies` already
    /// drops attachments and every part nested under `message/rfc822`.
    static func readOrder(_ parts: [MessagePart]) -> [MessagePart] {
        let bodies = Message(header: MessageInfo(sequenceNumber: SequenceNumber(0)), parts: parts).bodies
        var selected: [MessagePart] = []
        if let plain = bodies.first(where: { $0.contentType.lowercased().hasPrefix("text/plain") }) {
            selected.append(plain)
        }
        if let html = bodies.first(where: { $0.contentType.lowercased().hasPrefix("text/html") }) {
            selected.append(html)
        }
        return selected
    }

    /// Preserve MIME boundaries: a signature or label in one alternative must not
    /// hide a code or create a match in the next. Oversize text is never partially parsed.
    static func decode(
        subject rawSubject: String?,
        sender rawSender: String?,
        parts: [(GmailTextPart, Data)],
        maxBytes: Int
    ) -> GmailDecodeOutcome {
        var bodies: [String] = []
        var links: [MailLink] = []
        var extractedLinkBytes = 0
        var undecodable = false
        var encodedBytes = 0
        var normalizedBytes = 0
        for (part, bytes) in parts {
            encodedBytes += bytes.count
            if encodedBytes > maxBytes { return .notice(GmailNotice.oversized) }
            guard let decoded = render(part, bytes: bytes) else {
                undecodable = true
                continue
            }
            normalizedBytes += decoded.text.utf8.count
            if normalizedBytes > maxBytes { return .notice(GmailNotice.oversized) }
            if !decoded.text.isEmpty { bodies.append(decoded.text) }
            for link in decoded.links where links.count < 64 {
                let bytes = link.href.utf8.count + link.text.utf8.count
                guard bytes <= 8_704, extractedLinkBytes + bytes <= maxBytes else { continue }
                extractedLinkBytes += bytes
                links.append(link)
            }
        }
        if bodies.isEmpty, links.isEmpty {
            return .notice(undecodable ? GmailNotice.undecodable : GmailNotice.noText)
        }
        let subject = header(rawSubject)
        let sender = header(rawSender)
        return .message(
            GmailDecodedMail(
                subject: subject.failed ? "（主题无法解码）" : (subject.text.isEmpty ? "（无主题）" : subject.text),
                sender: sender.failed ? "（发件人无法解码）" : (sender.text.isEmpty ? "（未知发件人）" : sender.text),
                bodies: bodies, links: links, hasUndecodablePart: undecodable
            ))
    }

    private struct RenderedPart {
        var text: String
        var links: [MailLink]
    }

    private static func render(_ part: GmailTextPart, bytes: Data) -> RenderedPart? {
        guard let decoded = transferDecoded(bytes, encoding: part.transferEncoding) else { return nil }
        guard let text = string(decoded, charset: charset(from: part.mime)) else { return nil }
        if part.mime.lowercased().hasPrefix("text/html") {
            let body = htmlToText(text)
            let links = htmlLinks(text).map { link in
                let nearby = nearbyContext(for: link.text, in: body)
                return MailLink(
                    href: link.href, text: link.text,
                    context: [link.context, nearby].filter { !$0.isEmpty }.joined(separator: "\n"))
            }
            return RenderedPart(text: body, links: links)
        }
        return RenderedPart(text: text, links: [])
    }

    private static func nearbyContext(for anchorText: String, in body: String) -> String {
        let anchor = anchorText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !anchor.isEmpty else { return "" }
        let lines = body.components(separatedBy: .newlines)
        guard let index = lines.firstIndex(where: { $0.localizedCaseInsensitiveContains(anchor) }) else {
            return ""
        }
        let start = max(0, index - 1)
        let end = min(lines.count - 1, index + 1)
        return lines[start...end].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct HeaderRead {
        var text: String
        var failed: Bool
    }

    private static func header(_ raw: String?) -> HeaderRead {
        guard let raw else { return HeaderRead(text: "", failed: false) }
        let decoded = raw.decodeMIMEHeader()
        if decoded.range(of: #"=\?[^\s?]+\?[BbQq]\?[^?]*\?="#, options: .regularExpression) != nil {
            return HeaderRead(text: "", failed: true)
        }
        let scalars = decoded.unicodeScalars.filter { $0.value >= 32 || $0 == "\t" }
        var text = ""
        text.unicodeScalars.append(contentsOf: scalars)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 300 {
            text = String(text.prefix(300))
        }
        return HeaderRead(text: text, failed: false)
    }

    private static func normalizedEncoding(_ raw: String?) -> String {
        let compact = (raw ?? "").lowercased().filter { $0.isLetter || $0.isNumber }
        if compact.isEmpty || compact == "7bit" || compact == "8bit" || compact == "binary"
            || compact.hasSuffix("sevenbit") || compact.hasSuffix("eightbit")
        {
            return "7bit"
        }
        if compact.hasSuffix("base64") { return "base64" }
        if compact.contains("quoted") { return "quoted-printable" }
        return "unknown"
    }

    private static func transferDecoded(_ data: Data, encoding: String?) -> Data? {
        switch normalizedEncoding(encoding) {
        case "7bit":
            return data
        case "base64":
            let cleaned =
                String(data: data, encoding: .ascii)?
                .filter { !$0.isWhitespace && !$0.isNewline } ?? ""
            guard !cleaned.isEmpty else { return data.isEmpty ? Data() : nil }
            let padded = cleaned.padding(
                toLength: ((cleaned.count + 3) / 4) * 4, withPad: "=", startingAt: 0)
            return Data(base64Encoded: padded)
        case "quoted-printable":
            let carrier = MessagePart(
                section: Section([1]), contentType: "text/plain", encoding: "quoted-printable")
            return data.decoded(for: carrier)
        default:
            return nil
        }
    }

    private static func charset(from mime: String) -> String? {
        let pieces = mime.split(separator: ";").dropFirst()
        for piece in pieces {
            let pair = piece.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard pair.count == 2, pair[0].lowercased() == "charset" else { continue }
            return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    private static func string(_ data: Data, charset: String?) -> String? {
        if data.isEmpty { return "" }
        switch charset?.lowercased().replacingOccurrences(of: "_", with: "-") {
        case nil, "", "utf-8", "utf8", "us-ascii", "ascii":
            return String(data: data, encoding: .utf8)
        case "iso-8859-1", "latin1":
            return String(data: data, encoding: .isoLatin1)
        case "windows-1252", "cp1252":
            return String(data: data, encoding: .windowsCP1252)
        case "utf-16":
            return String(data: data, encoding: .utf16)
        case "gb2312", "gbk", "gb18030", "cp936":
            return String(data: data, encoding: chineseLegacyEncoding)
        default:
            return nil
        }
    }

    static func htmlToText(_ html: String) -> String {
        var output = ""
        var index = html.startIndex
        while index < html.endIndex {
            if html[index] == "<", let tag = readTag(html, at: index) {
                if tag.opensQuotedSubtree, let end = skipElement(html, named: tag.name, from: tag.end) {
                    output.append("\n")
                    index = end
                    continue
                }
                if tag.name == "script" || tag.name == "style", tag.opensElement,
                    let end = skipElement(html, named: tag.name, from: tag.end)
                {
                    index = end
                    continue
                }
                if tag.breaksLine { output.append("\n") }
                index = tag.end
                continue
            }
            output.append(html[index])
            index = html.index(after: index)
        }
        return decodeEntities(output).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct HTMLTag {
        var name: String
        var end: String.Index
        var attributes: Substring
        var isClosing: Bool
        var opensElement: Bool
        var opensQuotedSubtree: Bool
        var breaksLine: Bool
    }

    private static func readTag(_ html: String, at start: String.Index) -> HTMLTag? {
        guard html[start] == "<" else { return nil }
        var index = html.index(after: start)
        if index < html.endIndex, html[index] == "!" {
            if html[index...].hasPrefix("!--"), let end = html[index...].range(of: "-->")?.upperBound {
                return HTMLTag(
                    name: "", end: end, attributes: "", isClosing: false,
                    opensElement: false, opensQuotedSubtree: false, breaksLine: false)
            }
            guard let close = html[index...].firstIndex(of: ">") else { return nil }
            return HTMLTag(
                name: "", end: html.index(after: close), attributes: "", isClosing: false,
                opensElement: false,
                opensQuotedSubtree: false, breaksLine: false)
        }
        let closing = index < html.endIndex && html[index] == "/"
        if closing { index = html.index(after: index) }
        let nameStart = index
        while index < html.endIndex, html[index].isLetter || html[index].isNumber {
            index = html.index(after: index)
        }
        guard index > nameStart, let close = tagEnd(html, from: index) else { return nil }
        let name = html[nameStart..<index].lowercased()
        let attributes = html[index..<close]
        let selfClosing = html[start...close].hasSuffix("/>") || closing
        let opensElement = !closing && !selfClosing
        let quoted = opensElement && (name == "blockquote" || hasQuoteClass(html[index..<close]))
        let breaks = ["br", "p", "div", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6"].contains(name)
        return HTMLTag(
            name: name, end: html.index(after: close), attributes: attributes,
            isClosing: closing, opensElement: opensElement,
            opensQuotedSubtree: quoted, breaksLine: breaks)
    }

    /// Extracts bounded visible anchor text and hrefs without loading remote content.
    private static func htmlLinks(_ html: String) -> [MailLink] {
        struct ContextLine {
            var text: String
            var linkIndexes: [Int]
        }

        var result: [MailLink] = []
        var lines: [ContextLine] = []
        var lineText = ""
        var lineBytes = 0
        var lineLinkIndexes: [Int] = []
        var href: String?
        var visibleText = ""
        var index = html.startIndex

        func flushLine() {
            guard !lineText.isEmpty || !lineLinkIndexes.isEmpty else { return }
            lines.append(ContextLine(text: lineText, linkIndexes: lineLinkIndexes))
            lineText = ""
            lineBytes = 0
            lineLinkIndexes = []
        }

        func appendCurrent() {
            guard let href else { return }
            let text = visibleText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !href.isEmpty, href.utf8.count <= 8_192 else { return }
            result.append(MailLink(href: href, text: String(text.prefix(512))))
            lineLinkIndexes.append(result.count - 1)
        }

        while index < html.endIndex, result.count < 64 {
            if html[index] == "<", let tag = readTag(html, at: index) {
                if tag.opensQuotedSubtree,
                    let end = skipElement(html, named: tag.name, from: tag.end)
                {
                    index = end
                    continue
                }
                if tag.name == "script" || tag.name == "style", tag.opensElement,
                    let end = skipElement(html, named: tag.name, from: tag.end)
                {
                    index = end
                    continue
                }
                if tag.breaksLine || tag.name == "br" { flushLine() }
                if tag.name == "a", tag.isClosing {
                    appendCurrent()
                    href = nil
                    visibleText = ""
                } else if tag.name == "a", tag.opensElement {
                    if href != nil { appendCurrent() }
                    href = attribute("href", in: tag.attributes).map(decodeEntities)
                    visibleText = ""
                } else if href != nil && (tag.breaksLine || tag.name == "br") {
                    visibleText.append(" ")
                }
                index = tag.end
                continue
            }
            let character = html[index]
            if lineBytes < 4_096 {
                lineText.append(character)
                lineBytes += character.utf8.count
            }
            if href != nil, visibleText.utf8.count < 1_024 { visibleText.append(character) }
            index = html.index(after: index)
        }
        if href != nil { appendCurrent() }
        flushLine()

        var contexts = Array(repeating: "", count: result.count)
        let visibleLineIndexes = lines.indices.filter {
            !lines[$0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        for lineIndex in lines.indices where !lines[lineIndex].linkIndexes.isEmpty {
            // Empty HTML blocks can create several adjacent empty lines. Keep only
            // the nearest preceding visible block so later footer text cannot taint it.
            let previous = visibleLineIndexes.last { $0 < lineIndex }
            let contextIndexes = [previous, Optional(lineIndex)].compactMap { $0 }
            let context = contextIndexes.map { lines[$0].text }.joined(separator: " ")
            for linkIndex in lines[lineIndex].linkIndexes where contexts.indices.contains(linkIndex) {
                contexts[linkIndex] = String(context.prefix(2_048))
            }
        }
        return result.enumerated().map { index, link in
            MailLink(href: link.href, text: link.text, context: contexts[index])
        }
    }

    private static func attribute(_ target: String, in attributes: Substring) -> String? {
        var rest = attributes[...]
        while !rest.isEmpty {
            rest = rest.drop(while: { $0.isWhitespace || $0 == "/" })
            guard !rest.isEmpty else { break }
            let name = rest.prefix { !$0.isWhitespace && $0 != "=" && $0 != "/" }
            guard !name.isEmpty else {
                rest = rest.dropFirst()
                continue
            }
            rest = rest.dropFirst(name.count).drop(while: \.isWhitespace)
            guard rest.first == "=" else { continue }
            rest = rest.dropFirst().drop(while: \.isWhitespace)
            let value: Substring
            if let quote = rest.first, quote == "\"" || quote == "'" {
                rest = rest.dropFirst()
                value = rest.prefix { $0 != quote }
                rest = rest.dropFirst(value.count)
                if !rest.isEmpty { rest = rest.dropFirst() }
            } else {
                value = rest.prefix { !$0.isWhitespace }
                rest = rest.dropFirst(value.count)
            }
            if name.lowercased() == target { return String(value) }
        }
        return nil
    }

    private static func tagEnd(_ html: String, from start: String.Index) -> String.Index? {
        var quote: Character?
        var index = start
        while index < html.endIndex {
            let character = html[index]
            if let delimiter = quote {
                if character == delimiter { quote = nil }
            } else {
                if character == ">" { return index }
                if character == "<" { return nil }
                if character == "\"" || character == "'" { quote = character }
            }
            index = html.index(after: index)
        }
        return nil
    }

    private static func hasQuoteClass(_ attributes: Substring) -> Bool {
        var rest = attributes[...]
        while !rest.isEmpty {
            rest = rest.drop(while: { $0.isWhitespace || $0 == "/" })
            let name = rest.prefix { !$0.isWhitespace && $0 != "=" && $0 != "/" }
            rest = rest.dropFirst(name.count).drop(while: \.isWhitespace)
            guard rest.first == "=" else { continue }
            rest = rest.dropFirst().drop(while: \.isWhitespace)
            let value: Substring
            if let quote = rest.first, quote == "\"" || quote == "'" {
                rest = rest.dropFirst()
                value = rest.prefix { $0 != quote }
                rest = rest.dropFirst(value.count)
                if !rest.isEmpty { rest = rest.dropFirst() }
            } else {
                value = rest.prefix { !$0.isWhitespace }
                rest = rest.dropFirst(value.count)
            }
            if name.lowercased() == "class",
                value.lowercased().split(whereSeparator: \.isWhitespace).contains(where: {
                    $0.hasPrefix("gmail_quote")
                })
            {
                return true
            }
        }
        return false
    }

    /// Drops a nested element through its matching end tag. An unclosed quote drops the rest,
    /// so an old code cannot survive a missing closer.
    private static func skipElement(_ html: String, named name: String, from start: String.Index) -> String
        .Index?
    {
        guard !name.isEmpty else { return start }
        var depth = 1
        var index = start
        while index < html.endIndex {
            if html[index] != "<" {
                index = html.index(after: index)
                continue
            }
            guard let tag = readTag(html, at: index) else {
                index = html.index(after: index)
                continue
            }
            if tag.name == name {
                if tag.opensElement {
                    depth += 1
                } else if html[index...].dropFirst().first == "/" {
                    depth -= 1
                    if depth == 0 { return tag.end }
                }
            }
            index = tag.end
        }
        return html.endIndex
    }

    private static func decodeEntities(_ text: String) -> String {
        let maxSpan = 12
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "&", let after = text.index(index, offsetBy: 1, limitedBy: text.endIndex),
                after < text.endIndex,
                let farthest = text.index(
                    index, offsetBy: maxSpan, limitedBy: text.index(before: text.endIndex))
                    ?? Optional(text.index(before: text.endIndex)),
                farthest >= after,
                let semicolon = text[after...farthest].firstIndex(of: ";")
            {
                let token = text[after..<semicolon]
                if let scalar = entity(token) {
                    result.unicodeScalars.append(scalar)
                    index = text.index(after: semicolon)
                    continue
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    private static func entity(_ token: Substring) -> Unicode.Scalar? {
        switch token.lowercased() {
        case "amp": return Unicode.Scalar(38)
        case "lt": return Unicode.Scalar(60)
        case "gt": return Unicode.Scalar(62)
        case "quot": return Unicode.Scalar(34)
        case "apos", "#39": return Unicode.Scalar(39)
        case "nbsp": return Unicode.Scalar(32)
        default:
            if token.hasPrefix("#x"), let value = UInt32(token.dropFirst(2), radix: 16) {
                return Unicode.Scalar(value)
            }
            if token.hasPrefix("#"), let value = UInt32(token.dropFirst(), radix: 10) {
                return Unicode.Scalar(value)
            }
            return nil
        }
    }
}
