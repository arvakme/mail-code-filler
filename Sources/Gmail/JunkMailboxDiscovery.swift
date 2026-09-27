import Foundation
import MailCodeCore
import SwiftMail

/// Matches only selectable folders reported by LIST. The returned name is the wire
/// name, so modified UTF-7 can be passed back to EXAMINE without a lossy round trip.
enum JunkMailboxDiscovery {
    static func discover(on server: IMAPServer, provider: IMAPProvider) async throws -> String? {
        let listed = try await server.listMailboxes()
        if let selected = choose(listed, provider: provider),
            listed.contains(where: { $0.name == selected && $0.attributes.contains(.junk) })
        {
            return selected
        }
        let capabilities = (try? await server.fetchCapabilities()) ?? []
        if capabilities.contains(where: {
            $0.name.compare("SPECIAL-USE", options: .caseInsensitive) == .orderedSame
        }) {
            if let special = try? await server.listSpecialUseMailboxes(),
                let selected = special.first(where: {
                    $0.isSelectable && $0.attributes.contains(.junk)
                })
            {
                return selected.name
            }
        }
        return choose(listed, provider: provider)
    }

    static func choose(_ listed: [Mailbox.Info], provider: IMAPProvider) -> String? {
        let selectable = listed.filter(\.isSelectable)
        if let special = selectable.first(where: { $0.attributes.contains(.junk) }) {
            return special.name
        }
        let names = fallbackNames(for: provider)
        return selectable.first { box in
            let decoded = decodeModifiedUTF7(box.name)
            if names.contains(where: { $0.caseInsensitiveCompare(decoded) == .orderedSame }) {
                return true
            }
            guard provider == .gmail else { return false }
            let parts = decoded.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2,
                ["[Gmail]", "[Google Mail]"].contains(where: {
                    $0.caseInsensitiveCompare(String(parts[0])) == .orderedSame
                })
            else { return false }
            return ["Spam", "垃圾邮件", "スパム", "Courrier indésirable", "Correo no deseado"]
                .contains { $0.caseInsensitiveCompare(String(parts[1])) == .orderedSame }
        }?.name
    }

    static func fallbackNames(for provider: IMAPProvider) -> [String] {
        switch provider {
        case .gmail: ["[Gmail]/Spam", "[Google Mail]/Spam"]
        case .outlook: ["Junk Email", "Junk"]
        case .icloudMail: ["Junk"]
        case .qqMail: ["Junk", "垃圾邮件", "Junk Mail"]
        case .neteaseMail: ["垃圾邮件"]
        }
    }

    private static func decodeModifiedUTF7(_ name: String) -> String {
        var result = ""
        var rest = name[...]
        while let start = rest.firstIndex(of: "&") {
            result += rest[..<start]
            rest = rest[rest.index(after: start)...]
            guard let end = rest.firstIndex(of: "-") else {
                result += "&" + rest
                return result
            }
            let encoded = String(rest[..<end])
            if encoded.isEmpty {
                result += "&"
            } else {
                var base64 = encoded.replacingOccurrences(of: ",", with: "/")
                base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
                if let bytes = Data(base64Encoded: base64),
                    let decoded = String(data: bytes, encoding: .utf16BigEndian)
                {
                    result += decoded
                } else {
                    result += "&" + encoded + "-"
                }
            }
            rest = rest[rest.index(after: end)...]
        }
        return result + rest
    }
}
