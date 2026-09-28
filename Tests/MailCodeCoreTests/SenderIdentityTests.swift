import Foundation
import Testing

@testable import MailCodeCore

struct SenderIdentityTests {
    @Test func quotedNameAndMailSubdomainResolveFromTheActualDomain() {
        let identity = SenderIdentity(fromHeader: "\"GitHub Support\" <noreply@notifications.github.com>")
        #expect(identity.displayName == "GitHub Support")
        #expect(identity.domain == "notifications.github.com")
        #expect(identity.registrableDomain == "github.com")
        #expect(identity.isKnownService)
        #expect(identity.iconAssetName == "SenderGitHub")
        #expect(identity.iconPresentation == .original)
    }

    @Test func idnAndCountrySubdomainsReduceToRegistrableDomain() {
        let idn = SenderIdentity(fromHeader: "Support <login@accounts.bücher.de>")
        #expect(idn.domain == "accounts.xn--bcher-kva.de")
        #expect(idn.registrableDomain == "xn--bcher-kva.de")
        #expect(SenderIdentity.registrableDomain(for: "mail.service.example.co.uk") == "example.co.uk")
    }

    @Test func bareAddressAndMissingDomainUseSafeFallbacks() {
        let known = SenderIdentity(fromHeader: "noreply@google.com")
        #expect(known.displayName == "Google")
        #expect(known.domain == "google.com")
        let missing = SenderIdentity(fromHeader: "\"Example Team\"")
        #expect(missing.domain == nil)
        #expect(missing.displayName == "\"Example Team\"")
        #expect(!missing.isKnownService)
    }

    @Test func unknownAndSpoofedNamesNeverCreateBrandMatches() {
        let unknown = SenderIdentity(fromHeader: "GitHub <noreply@github-login.security>")
        #expect(!unknown.isKnownService)
        #expect(unknown.iconAssetName == nil)
        #expect(unknown.displayName == "GitHub")
        #expect(unknown.registrableDomain == "github-login.security")
        let actual = SenderIdentity(fromHeader: "Security Desk <notice@github.com>")
        #expect(actual.isKnownService)
        #expect(actual.displayName == "Security Desk")
        #expect(actual.registrableDomain == "github.com")
    }

    @Test func fallbackColorIsStablePerRegistrableDomain() {
        let subdomain = SenderIdentity(fromHeader: "Code <a@mail.example.test>")
        let root = SenderIdentity(fromHeader: "Code <a@example.test>")
        let other = SenderIdentity(fromHeader: "Code <a@other.test>")
        #expect(subdomain.colorHex == root.colorHex)
        #expect(root.colorHex != other.colorHex)
    }

    @Test func commonSenderCatalogCoversRequestedGlobalAndChineseServices() {
        #expect(CommonSender.brandRecords.count >= 100)
        for domain in [
            "github.com", "apple.com", "anthropic.com", "stripe.com", "google.com", "taobao.com", "12306.cn",
            "huawei.com", "alipay.com", "aliyun.com", "feishu.cn", "icbc.com.cn", "accounts.google.com",
            "service.mail.qq.com",
        ] {
            #expect(CommonSender.services[domain] != nil)
        }
        for domain in CommonSender.personalMailboxDomains {
            #expect(CommonSender.services[domain] == nil, "Personal mailbox domain mapped: \(domain)")
        }
    }

    @Test func knownSubdomainsAndMultipleDomainsResolveToOneBrand() {
        let examples: [(String, String)] = [
            ("accounts.google.com", "Google"),
            ("google.com", "Google"),
            ("mail.anthropic.com", "Anthropic"),
            ("notifications.github.com", "GitHub"),
            ("service.alipay.com", "支付宝"),
            ("service.mail.qq.com", "QQ"),
            ("10000.qq.com", "QQ"),
            ("netease.com", "网易"),
            ("twitter.com", "X"),
            ("ctrip.com", "Trip.com"),
        ]
        for (domain, expectedName) in examples {
            let identity = SenderIdentity(fromHeader: "noreply@\(domain)")
            #expect(identity.isKnownService)
            #expect(identity.displayName == expectedName)
        }

        let slack = SenderIdentity(fromHeader: "Slack <noreply@slack.com>")
        #expect(slack.iconAssetName == "SenderSlack")
        #expect(slack.iconPresentation == .original)
    }

    @Test func personalMailboxDomainsUseDisplayNameInitialsInsteadOfBrandIdentity() {
        for domain in [
            "gmail.com", "googlemail.com", "qq.com", "foxmail.com", "163.com", "126.com", "yeah.net",
            "outlook.com", "hotmail.com", "live.com", "icloud.com", "me.com", "yahoo.com", "proton.me",
        ] {
            let identity = SenderIdentity(fromHeader: "Alice <alice@\(domain)>")
            #expect(!identity.isKnownService, "Personal mailbox domain matched a brand: \(domain)")
            #expect(identity.iconAssetName == nil)
            #expect(identity.displayName == "Alice")
            #expect(identity.monogram == "A")
        }

        let unlistedGoogleSubdomain = SenderIdentity(fromHeader: "Alice <alice@promo.google.com>")
        #expect(!unlistedGoogleSubdomain.isKnownService)
        #expect(unlistedGoogleSubdomain.iconAssetName == nil)
        #expect(unlistedGoogleSubdomain.monogram == "A")
    }

    @Test func localBrandIconsAreOptionalAndUseNormalizedRasterAssets() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogRoot = repositoryRoot.appendingPathComponent("Sources/App/Assets.xcassets")
        let iconRecords = CommonSender.brandRecords.compactMap { record -> (String, String)? in
            guard let asset = record.iconAssetName else { return nil }
            return (record.name, asset)
        }
        for (brand, asset) in iconRecords {
            let imageset = catalogRoot.appendingPathComponent("\(asset).imageset")
            guard FileManager.default.fileExists(atPath: imageset.path) else { continue }
            let contents = try #require(
                try JSONSerialization.jsonObject(
                    with: Data(contentsOf: imageset.appendingPathComponent("Contents.json")))
                    as? [String: Any])
            let images = try #require(contents["images"] as? [[String: String]])
            #expect(images.count == 3, "Invalid PNG scale count for \(brand): \(asset)")
            #expect(
                Set(images.compactMap { $0["scale"] }) == Set(["1x", "2x", "3x"]),
                "Invalid PNG scales for \(brand): \(asset)")
            for scale in ["1x", "2x", "3x"] {
                #expect(
                    images.contains(["filename": "sender-\(scale).png", "idiom": "universal", "scale": scale]
                    ),
                    "Invalid \(scale) PNG mapping for \(brand): \(asset)")
                #expect(
                    FileManager.default.fileExists(
                        atPath: imageset.appendingPathComponent("sender-\(scale).png").path),
                    "Missing \(scale) PNG for \(brand): \(asset)")
            }
        }
    }
}
