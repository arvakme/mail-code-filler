import Foundation
import MailCodeCore
import SwiftMail
import Testing

@testable import MailCodeGmail

@Suite("Junk folder discovery and cadence", .serialized)
struct JunkMailboxBehaviorTests {
    @Test func specialUseReturnWinsOverFallbackAndRefetchesSelectedMailbox() async throws {
        let name = "Unusual"
        let server = IMAPScriptServer(
            username: "person@gmail.com", password: "abcdefghijklmnop",
            extraMailboxes: [
                ScriptMailbox(
                    name: name, attributes: "", specialUseAttributes: "\\Junk",
                    uidValidity: 29, messages: [message(uid: 3, text: "code 654321")]),
                ScriptMailbox(
                    name: "[Gmail]/Spam", attributes: "", uidValidity: 31,
                    messages: [message(uid: 4, text: "code 123456")]),
            ], capabilities: ["IMAP4rev1", "IDLE", "SPECIAL-USE"])
        try server.start()
        defer { server.stop() }
        let events = MailEvents()
        let feed = IMAPAccountFeed(
            configuration: .testing(port: server.port, now: Date.init),
            checksJunkFolder: { true })
        let login = IMAPAccountCredentials(email: "person@gmail.com", appPassword: "abcdefghijklmnop")
        let task = Task { try await feed.run(login: login) { await events.add($0) } }
        defer { task.cancel() }
        let mail = try await events.waitFor(mailbox: name, count: 1).first!
        #expect(mail.id.uidValidity == 29)
        #expect(mail.isFromJunk)
        #expect(
            server.commandLog.contains {
                $0.uppercased().contains("LIST") && $0.uppercased().contains("SPECIAL-USE")
            })
        task.cancel()
        _ = await task.result

        let fetcher = GmailMissedMailFetcher(host: "127.0.0.1", port: server.port, security: .plainText)
        let fetched = try await fetcher.fetchReadOnly(login: login, message: mail.id)
        #expect(fetched.isFromJunk)
        #expect(fetched.bodies == ["code 654321"])
        #expect(server.commandLog.contains { $0.contains("EXAMINE \"Unusual\"") })
    }

    @Test func modifiedUTF7NameSurvivesDiscoveryAndReadOnlyRefetch() async throws {
        let encoded = "&V4NXPpCuTvY-"
        let server = IMAPScriptServer(
            username: "person@qq.com", password: "qq-secret",
            extraMailboxes: [
                ScriptMailbox(
                    name: encoded, attributes: "", uidValidity: 12,
                    messages: [message(uid: 8, text: "code 654321")])
            ])
        try server.start()
        defer { server.stop() }
        let events = MailEvents()
        let login = IMAPAccountCredentials(provider: .qqMail, email: "person@qq.com", secret: "qq-secret")
        let feed = IMAPAccountFeed(
            configuration: .testing(port: server.port, provider: .qqMail, now: Date.init),
            checksJunkFolder: { true })
        let task = Task { try await feed.run(login: login) { await events.add($0) } }
        defer { task.cancel() }
        let mail = try await events.waitFor(mailbox: encoded, count: 1).first!
        task.cancel()
        _ = await task.result
        #expect(mail.id.mailbox == encoded)
        let fetcher = GmailMissedMailFetcher(host: "127.0.0.1", port: server.port, security: .plainText)
        let fetched = try await fetcher.fetchReadOnly(login: login, message: mail.id)
        #expect(fetched.bodies == ["code 654321"])
        let commands = server.commandLog.joined(separator: "\n").uppercased()
        #expect(commands.contains("EXAMINE \"&V4NXPPCUTVY-\""))
        #expect(!commands.contains(" STORE "))
    }

    @Test func codeWaitRechecksJunkWithoutBreakingInboxIdleOrOpeningConnection() async throws {
        let server = IMAPScriptServer(
            username: "person@gmail.com", password: "abcdefghijklmnop",
            extraMailboxes: [
                ScriptMailbox(
                    name: "Spam", attributes: "\\Junk", uidValidity: 5,
                    messages: [])
            ])
        try server.start()
        defer { server.stop() }
        let signal = CodeWaitModeController(duration: .seconds(2))
        let feed = IMAPAccountFeed(
            configuration: .testing(
                port: server.port, now: Date.init,
                livenessInterval: .seconds(5), junkInterval: .seconds(5),
                codeWaitJunkInterval: .milliseconds(40)),
            codeWaitSignal: signal, checksJunkFolder: { true })
        let task = Task {
            try await feed.run(login: .init(email: "person@gmail.com", appPassword: "abcdefghijklmnop")) {
                _ in
            }
        }
        defer { task.cancel() }
        try await server.waitUntil { $0.contains { $0.contains(" EXAMINE \"Spam\"") } }
        await signal.begin(.manual)
        try await server.waitUntil { lines in lines.filter { $0.contains(" EXAMINE \"Spam\"") }.count >= 3 }
        let commands = server.commandLog.joined(separator: "\n").uppercased()
        #expect(server.acceptedConnectionCount == 2)
        #expect(commands.contains(" IDLE"))
        #expect(!commands.contains("DONE"))
        #expect(!commands.contains(" SELECT "))
        task.cancel()
        _ = await task.result
    }

    private func message(uid: UInt32, text: String) -> ScriptMessage {
        ScriptMessage(
            uid: uid, subject: "Verification", from: "sender@example.test",
            internalDate: Date(), envelopeDate: "Thu, 01 Jan 1999 00:00:00 +0000",
            mime: "text/plain", charset: "utf-8", transferEncoding: "7BIT",
            body: Data(text.utf8))
    }
}

private actor MailEvents {
    private var received: [ReceivedMail] = []

    func add(_ event: IMAPFeedEvent) {
        if case .message(let mail) = event { received.append(mail) }
    }

    func waitFor(mailbox: String, count: Int) async throws -> [ReceivedMail] {
        for _ in 0..<200 {
            let found = received.filter { $0.id.mailbox == mailbox }
            if found.count >= count { return found }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ScriptServerError("timed out waiting for junk mailbox event")
    }
}
