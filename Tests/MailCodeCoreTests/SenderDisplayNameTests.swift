import Testing

@testable import MailCodeCore

struct SenderDisplayNameTests {
    @Test func extractsNameAndUnquotesHeader() {
        #expect(SenderDisplayName.fromHeader("GitHub <noreply@github.com>") == "GitHub")
        #expect(
            SenderDisplayName.fromHeader("\"GitHub Support\" <noreply@github.com>")
                == "GitHub Support")
        #expect(
            SenderDisplayName.fromHeader("\"Support \\\"Team\\\"\" <noreply@github.com>")
                == "Support \"Team\"")
    }

    @Test func keepsBareAddressAndTrimsWhitespace() {
        #expect(SenderDisplayName.fromHeader("noreply@github.com") == "noreply@github.com")
        #expect(SenderDisplayName.fromHeader("  noreply@github.com  ") == "noreply@github.com")
    }
}
