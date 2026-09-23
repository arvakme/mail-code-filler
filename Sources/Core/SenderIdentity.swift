import Foundation

public enum SenderIconPresentation: String, Decodable, Sendable {
    case template
    case original
}

/// A local, privacy-preserving identity derived from the untrusted From header.
/// Brand lookup uses exact cataloged sender domains; display names never establish a brand.
public struct SenderIdentity: Equatable, Sendable {
    public let displayName: String
    public let domain: String?
    public let registrableDomain: String?
    public let monogram: String
    public let colorHex: UInt32
    public let iconAssetName: String?
    public let iconPresentation: SenderIconPresentation
    public let isKnownService: Bool

    public init(fromHeader header: String) {
        let parsedName = SenderDisplayName.fromHeader(header).trimmingCharacters(in: .whitespacesAndNewlines)
        let address = Self.address(from: header)
        let rawDomain = address?.split(separator: "@", maxSplits: 1).last.map(String.init)
        let domain = rawDomain.flatMap(Self.normalizeDomain)
        let registrable = domain.map(Self.registrableDomain(for:))
        let service = domain.flatMap { CommonSender.services[$0] }
        let isAddress = parsedName.contains("@")
        let incomingName = parsedName.isEmpty || isAddress ? nil : parsedName
        let label: String
        if let incomingName, let service,
            !Self.normalizedName(incomingName).contains(Self.normalizedName(service.name))
        {
            // Preserve the header's label but always pair it with the actual domain.
            label = incomingName
        } else {
            label = incomingName ?? service?.name ?? registrable ?? domain ?? "未知发件方"
        }

        self.displayName = label
        self.domain = domain
        self.registrableDomain = registrable
        self.monogram = String(label.first ?? (registrable ?? domain ?? "?").first ?? "?").uppercased()
        self.colorHex =
            service?.colorHex
            ?? Self.stableColor(for: service?.colorSeed ?? registrable ?? domain ?? "unknown")
        self.iconAssetName = service?.iconAssetName
        self.iconPresentation = service?.iconPresentation ?? .template
        self.isKnownService = service != nil
    }

    public static func registrableDomain(for domain: String) -> String {
        let labels = domain.lowercased().split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return domain.lowercased() }
        let suffix = labels.suffix(2).joined(separator: ".")
        if CommonSender.compoundPublicSuffixes.contains(suffix), labels.count >= 3 {
            return labels.suffix(3).joined(separator: ".")
        }
        return suffix
    }

    public static func stableColor(for value: String) -> UInt32 {
        // FNV-1a is stable across processes and Swift versions, unlike Hasher.
        var hash: UInt32 = 2_166_136_261
        for byte in value.lowercased().utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        let hue = Double(hash % 360) / 360
        let saturation = 0.58
        let brightness = 0.78
        let (red, green, blue) = Self.hsv(hue: hue, saturation: saturation, brightness: brightness)
        return (UInt32(red * 255) << 16) | (UInt32(green * 255) << 8) | UInt32(blue * 255)
    }

    private static func address(from header: String) -> String? {
        let candidate: String
        if let open = header.lastIndex(of: "<"), let close = header[open...].firstIndex(of: ">") {
            candidate = String(header[header.index(after: open)..<close])
        } else {
            candidate = header.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let at = candidate.lastIndex(of: "@") else { return nil }
        let rawDomain = candidate[candidate.index(after: at)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: ". >\t\r\n"))
        guard !rawDomain.isEmpty else { return nil }
        return "local@\(rawDomain)"
    }

    private static func normalizeDomain(_ input: String) -> String? {
        let raw = input.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !raw.isEmpty else { return nil }
        let host = URL(string: "https://\(raw)")?.host ?? raw
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard normalized.contains("."), !normalized.contains(where: \.isWhitespace) else { return nil }
        return normalized
    }

    private static func normalizedName(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }

    private static func hsv(hue: Double, saturation: Double, brightness: Double) -> (Double, Double, Double) {
        let sector = hue * 6
        let index = Int(sector) % 6
        let fraction = sector - Double(Int(sector))
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - fraction * saturation)
        let t = brightness * (1 - (1 - fraction) * saturation)
        return switch index {
        case 0: (brightness, t, p)
        case 1: (q, brightness, p)
        case 2: (p, brightness, t)
        case 3: (p, q, brightness)
        case 4: (t, p, brightness)
        default: (brightness, p, q)
        }
    }
}

public enum CommonSender {
    static let personalMailboxDomains: Set<String> = [
        "gmail.com", "googlemail.com", "qq.com", "foxmail.com", "163.com", "126.com", "yeah.net",
        "vip.163.com", "vip.126.com", "outlook.com", "outlook.cn", "hotmail.com", "hotmail.co.uk",
        "hotmail.fr", "live.com", "live.co.uk", "msn.com", "icloud.com", "me.com", "mac.com",
        "yahoo.com", "yahoo.net", "yahoo.co.jp", "yahoo.co.uk", "yahoo.com.cn", "ymail.com",
        "rocketmail.com", "proton.me", "protonmail.com", "protonmail.ch", "pm.me", "aol.com",
        "fastmail.com", "tuta.com", "tutanota.com",
    ]

    struct BrandRecord: Decodable, Sendable {
        let name: String
        let domains: [String]
        let knownSendingSubdomains: [String]
        let colorHex: String?
        let iconAssetName: String?
        let iconPresentation: SenderIconPresentation?
    }

    public struct Service: Equatable, Sendable {
        public let name: String
        public let colorHex: UInt32?
        public let iconAssetName: String?
        public let iconPresentation: SenderIconPresentation
        public let colorSeed: String

        public init(
            name: String,
            colorHex: UInt32?,
            iconAssetName: String?,
            iconPresentation: SenderIconPresentation = .template,
            colorSeed: String? = nil
        ) {
            self.name = name
            self.colorHex = colorHex
            self.iconAssetName = iconAssetName
            self.iconPresentation = iconPresentation
            self.colorSeed = colorSeed ?? name.lowercased()
        }
    }

    /// Bundled once from the pinned, source-annotated sender catalog.
    static let brandRecords = loadBrandRecords()

    /// Explicitly cataloged sender domains; consumer mailbox providers are never brand keys.
    public static let services: [String: Service] = {
        var result: [String: Service] = [:]
        for brand in brandRecords {
            let color: UInt32?
            if let hex = brand.colorHex {
                guard let parsed = UInt32(hex, radix: 16) else {
                    preconditionFailure("Invalid sender brand color for \(brand.name): \(hex)")
                }
                color = parsed
            } else {
                color = nil
            }
            let service = Service(
                name: brand.name,
                colorHex: color,
                iconAssetName: brand.iconAssetName,
                iconPresentation: brand.iconPresentation ?? .template,
                colorSeed: brand.domains.first
            )
            for domain in brand.domains + brand.knownSendingSubdomains {
                let normalized = domain.lowercased()
                guard !personalMailboxDomains.contains(normalized) else { continue }
                result[normalized] = service
            }
        }
        return result
    }()

    static let compoundPublicSuffixes: Set<String> = [
        "co.uk", "org.uk", "com.cn", "net.cn", "org.cn", "com.au", "net.au", "org.au",
        "co.jp", "ne.jp", "or.jp", "co.nz", "com.sg", "com.hk", "com.tw", "com.br",
        "com.mx", "co.in", "firm.in", "net.in", "org.in",
    ]

    private static func loadBrandRecords() -> [BrandRecord] {
        guard let url = Bundle.module.url(forResource: "sender-brands", withExtension: "json") else {
            preconditionFailure("Missing bundled sender-brands.json")
        }
        do {
            return try JSONDecoder().decode([BrandRecord].self, from: Data(contentsOf: url))
        } catch {
            preconditionFailure("Unable to load sender-brands.json: \(error)")
        }
    }
}
