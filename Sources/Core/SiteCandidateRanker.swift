import Foundation

public struct RankedCandidate: Identifiable, Sendable {
    public let candidate: Candidate
    public let matchesCurrentSite: Bool

    public var id: Candidate.ID { candidate.id }

    public init(candidate: Candidate, matchesCurrentSite: Bool) {
        self.candidate = candidate
        self.matchesCurrentSite = matchesCurrentSite
    }
}

/// Matches only exact registrable domains or pairs listed in the bundled alias groups.
/// Sender display names and consumer mailbox domains cannot establish a match.
public struct CurrentSiteCandidateRanker: Sendable {
    private let aliasGroups: [[String]]

    public init(aliasGroups: [[String]]? = nil) {
        self.aliasGroups = (aliasGroups ?? Self.bundledAliasGroups).map { group in
            group.map { $0.lowercased() }
                .filter { $0.contains(".") && SenderIdentity.registrableDomain(for: $0) == $0 }
        }
    }

    public func matches(_ candidate: Candidate, page: ActivePage?) -> Bool {
        guard let page,
            let senderDomain = SenderIdentity(fromHeader: candidate.source).registrableDomain,
            !CommonSender.personalMailboxDomains.contains(senderDomain)
        else { return false }
        let site = page.registrableDomain.lowercased()
        if senderDomain == site { return true }
        return aliasGroups.contains { $0.contains(senderDomain) && $0.contains(site) }
    }

    public func rank(_ candidates: [Candidate], for page: ActivePage?) -> [RankedCandidate] {
        candidates.map { RankedCandidate(candidate: $0, matchesCurrentSite: matches($0, page: page)) }
            .sorted { lhs, rhs in
                if lhs.matchesCurrentSite != rhs.matchesCurrentSite { return lhs.matchesCurrentSite }
                if lhs.candidate.receivedAt != rhs.candidate.receivedAt {
                    return lhs.candidate.receivedAt > rhs.candidate.receivedAt
                }
                return Self.idPrecedes(lhs.id, rhs.id)
            }
    }

    public func bestCode(in candidates: [Candidate], for page: ActivePage?, now: Date = Date())
        -> Candidate?
    {
        rank(candidates.filter { $0.code != nil && $0.expiresAt > now }, for: page).first?.candidate
    }

    private static func idPrecedes(_ lhs: Candidate.ID, _ rhs: Candidate.ID) -> Bool {
        let a = lhs.message
        let b = rhs.message
        if a.account != b.account { return a.account < b.account }
        if a.mailbox != b.mailbox { return a.mailbox < b.mailbox }
        if a.uidValidity != b.uidValidity { return a.uidValidity < b.uidValidity }
        if a.uid != b.uid { return a.uid < b.uid }
        return lhs.index < rhs.index
    }

    private struct AliasCatalog: Decodable { let groups: [[String]] }

    private static let bundledAliasGroups: [[String]] = {
        guard let url = Bundle.module.url(forResource: "website-domain-aliases", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let catalog = try? JSONDecoder().decode(AliasCatalog.self, from: data)
        else { return [] }
        return catalog.groups
    }()
}

extension ActivePage {
    /// Reduces a browser URL immediately; no URL or path is retained in the result.
    public static func fromBrowserURL(_ url: URL) -> ActivePage? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
            components.user == nil, components.password == nil,
            let rawHost = components.host?.lowercased().trimmingCharacters(
                in: CharacterSet(charactersIn: ".")),
            rawHost.contains("."), !rawHost.contains(where: \.isWhitespace)
        else { return nil }
        let domain = SenderIdentity.registrableDomain(for: rawHost)
        let path =
            components.percentEncodedPath.removingPercentEncoding?.lowercased()
            ?? components.path.lowercased()
        let keywords = ["login", "signin", "verify", "otp", "2fa", "auth", "登录", "验证"]
        return ActivePage(
            registrableDomain: domain, host: rawHost,
            looksLikeAuthPage: keywords.contains { path.contains($0) })
    }
}
