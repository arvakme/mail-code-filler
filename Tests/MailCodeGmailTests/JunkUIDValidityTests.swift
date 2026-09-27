import Foundation
import MailCodeCore
import Testing

@testable import MailCodeGmail

@Suite("Junk mailbox UID validity", .serialized)
struct JunkUIDValidityTests {
    @Test func sameUIDIsReadAgainAfterJunkMailboxIsRecreated() async throws {
        let email = "person@gmail.com"
        let secret = "abcdefghijklmnop"
        let server = IMAPScriptServer(
            username: email, password: secret,
            extraMailboxes: [
                ScriptMailbox(
                    name: "Spam", attributes: "\\Junk", uidValidity: 1,
                    messages: [message("first code 123456")])
            ])
        try server.start()
        defer { server.stop() }
        let events = UIDEvents()
        let feed = IMAPAccountFeed(
            configuration: .testing(
                port: server.port, now: Date.init,
                junkInterval: .milliseconds(100)),
            checksJunkFolder: { true })
        let task = Task {
            try await feed.run(login: .init(email: email, appPassword: secret)) {
                await events.add($0)
            }
        }
        defer { task.cancel() }
        _ = try await events.waitFor(count: 1)
        server.replaceExtraMailbox(
            "Spam", uidValidity: 2,
            messages: [message("second code 654321")])
        let received = try await events.waitFor(count: 2)
        #expect(received.map(\.id.uid) == [1, 1])
        #expect(received.map(\.id.uidValidity) == [1, 2])
        #expect(received.map(\.bodies) == [["first code 123456"], ["second code 654321"]])
        task.cancel()
        _ = await task.result
    }

    private func message(_ text: String) -> ScriptMessage {
        ScriptMessage(
            uid: 1, subject: "Verification", from: "sender@example.test",
            internalDate: Date(), envelopeDate: "Thu, 01 Jan 1999 00:00:00 +0000",
            mime: "text/plain", charset: "utf-8", transferEncoding: "7BIT",
            body: Data(text.utf8))
    }
}

private actor UIDEvents {
    private var mails: [ReceivedMail] = []

    func add(_ event: IMAPFeedEvent) {
        if case .message(let mail) = event, mail.isFromJunk { mails.append(mail) }
    }

    func waitFor(count: Int) async throws -> [ReceivedMail] {
        for _ in 0..<200 {
            if mails.count >= count { return mails }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ScriptServerError("timed out waiting for junk UID validity change")
    }
}
