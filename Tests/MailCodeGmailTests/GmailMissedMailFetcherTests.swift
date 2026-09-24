import Foundation
import MailCodeCore
import Testing

@testable import MailCodeGmail

@Suite("MailCodeGmailTests.Refetch", .serialized)
struct GmailMissedMailFetcherTests {
    @Test func refetchUsesOnlyReadOnlyUIDPeek() async throws {
        let server = IMAPScriptServer(
            username: "person@gmail.com", password: "abcdefghijklmnop", uidValidity: 9,
            messages: [message()])
        try server.start()
        defer { server.stop() }
        let fetcher = GmailMissedMailFetcher(host: "127.0.0.1", port: server.port, security: .plainText)
        let result = try await fetcher.fetchReadOnly(login: login, message: identity(validity: 9))
        #expect(result.id == identity(validity: 9))
        #expect(result.bodies == ["test body"])
        let commands = server.commandLog.joined(separator: "\n").uppercased()
        #expect(commands.contains("EXAMINE \"INBOX\""))
        #expect(commands.contains("UID FETCH"))
        #expect(commands.contains("BODY.PEEK"))
        #expect(!commands.contains("SELECT "))
        #expect(!commands.contains(" STORE "))
    }

    @Test func changedValidityStopsBeforeUIDFetch() async throws {
        let server = IMAPScriptServer(
            username: "person@gmail.com", password: "abcdefghijklmnop", uidValidity: 10,
            messages: [message()])
        try server.start()
        defer { server.stop() }
        let fetcher = GmailMissedMailFetcher(host: "127.0.0.1", port: server.port, security: .plainText)
        await #expect(throws: IMAPMessageRefetchError.uidValidityChanged) {
            try await fetcher.fetchReadOnly(login: login, message: identity(validity: 9))
        }
        #expect(!server.commandLog.joined(separator: "\n").contains("UID FETCH"))
    }

    private var login: IMAPAccountCredentials {
        IMAPAccountCredentials(email: "person@gmail.com", appPassword: "abcdefghijklmnop")
    }

    private func identity(validity: UInt32) -> MailCodeCore.MessageID {
        MailCodeCore.MessageID(account: login.accountID, mailbox: "INBOX", uidValidity: validity, uid: 42)
    }

    private func message() -> ScriptMessage {
        ScriptMessage(
            uid: 42, subject: "Example", from: "sender@example.test", internalDate: Date(),
            envelopeDate: "Thu, 01 Jan 1999 00:00:00 +0000", mime: "text/plain", charset: "utf-8",
            transferEncoding: "7BIT", body: Data("test body".utf8))
    }
}
