import Foundation
import Testing

@testable import MailCodeCore

struct ActivePageTests {
    @Test func reducesURLToSafeFields() throws {
        let url = try #require(
            URL(string: "https://Account.Example.CO.UK:8443/%E9%AA%8C%E8%AF%81?token=secret#fragment"))
        let page = try #require(ActivePage.fromBrowserURL(url))
        #expect(page.host == "account.example.co.uk")
        #expect(page.registrableDomain == "example.co.uk")
        #expect(page.looksLikeAuthPage)
        #expect(String(describing: page).contains("secret") == false)
    }

    @Test func ignoresQueryAndFragmentForAuthHint() throws {
        let url = try #require(URL(string: "https://example.com/dashboard?next=/login#otp"))
        #expect(ActivePage.fromBrowserURL(url)?.looksLikeAuthPage == false)
    }

    @Test func rejectsNonWebAndCredentialURLs() throws {
        #expect(ActivePage.fromBrowserURL(try #require(URL(string: "file:///tmp/login"))) == nil)
        #expect(
            ActivePage.fromBrowserURL(try #require(URL(string: "https://user:pass@example.com/login"))) == nil
        )
    }

    @Test func acceptsInternationalHost() throws {
        let url = try #require(URL(string: "https://bücher.example/login"))
        let page = try #require(ActivePage.fromBrowserURL(url))
        #expect(page.host.contains("example"))
        #expect(page.looksLikeAuthPage)
    }
}
