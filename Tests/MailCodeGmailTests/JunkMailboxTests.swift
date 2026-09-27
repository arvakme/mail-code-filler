import Foundation
import MailCodeCore
import SwiftMail
import Testing

@testable import MailCodeGmail

@Suite("Junk mailbox read-only checks", .serialized)
struct JunkMailboxTests {
    private let email = "person@gmail.com"
    private let secret = "abcdefghijklmnop"

    @Test func specialUseMailProducesJunkCandidateWithoutDisturbingInboxIdle() async throws {
        let server = IMAPScriptServer(
            username: email, password: secret,
            messages: [message(uid: 7, text: "Your code is 123456")],
            extraMailboxes: [
                ScriptMailbox(
                    name: "Odd Folder", attributes: "\\Junk", uidValidity: 19,
                    messages: [message(uid: 7, text: "Your code is 654321")])
            ])
        try server.start()
        defer { server.stop() }
        let events = JunkEventLog()
        let feed = IMAPAccountFeed(
            configuration: .testing(
                port: server.port, now: Date.init,
                livenessInterval: .seconds(5), codeWaitLivenessInterval: .milliseconds(40)),
            checksJunkFolder: { true })
        let task = Task { try await feed.run(login: login) { event in await events.add(event) } }
        defer { task.cancel() }
        try await server.waitUntil { $0.contains { $0.contains(" EXAMINE \"Odd Folder\"") } }
        let mail = try await events.waitForJunk()
        #expect(mail.id.mailbox == "Odd Folder")
        #expect(mail.isFromJunk)
        #expect(server.acceptedConnectionCount == 2)
        let commands = server.commandLog.joined(separator: "\n").uppercased()
        #expect(commands.contains(" LIST "))
        #expect(commands.contains(" IDLE"))
        #expect(commands.contains("BODY.PEEK"))
        for forbidden in [" STORE ", " COPY ", " MOVE ", " EXPUNGE", " SELECT ", " CLOSE"] {
            #expect(!commands.contains(forbidden))
        }
        task.cancel()
        _ = await task.result
    }

    @Test func disabledSettingSendsNoJunkCommands() async throws {
        let server = IMAPScriptServer(
            username: email, password: secret,
            extraMailboxes: [
                ScriptMailbox(
                    name: "Spam", attributes: "\\Junk", uidValidity: 1,
                    messages: [message(uid: 1, text: "code 654321")])
            ])
        try server.start()
        defer { server.stop() }
        let feed = IMAPAccountFeed(
            configuration: .testing(port: server.port, now: Date.init),
            checksJunkFolder: { false })
        let task = Task { try await feed.run(login: login) { _ in } }
        defer { task.cancel() }
        try await server.waitUntil { $0.contains { $0.contains(" IDLE") } }
        let commands = server.commandLog.joined(separator: "\n").uppercased()
        #expect(!commands.contains(" LIST "))
        #expect(!commands.contains("SPAM"))
        task.cancel()
        _ = await task.result
    }

    @Test func providerFallbackSelectsListedNameOnly() {
        let examples: [(IMAPProvider, String)] = [
            (.gmail, "[Gmail]/Spam"), (.outlook, "Junk Email"),
            (.icloudMail, "Junk"), (.qqMail, "垃圾邮件"), (.neteaseMail, "垃圾邮件"),
        ]
        for (provider, name) in examples {
            let listed = [Mailbox.Info(name: name, attributes: [], hierarchyDelimiter: "/")]
            #expect(JunkMailboxDiscovery.choose(listed, provider: provider) == name)
        }
        #expect(
            JunkMailboxDiscovery.choose(
                [
                    Mailbox.Info(name: "Private/Junk notes", attributes: [], hierarchyDelimiter: "/")
                ], provider: .outlook) == nil)
    }

    private var login: IMAPAccountCredentials {
        .init(email: email, appPassword: secret)
    }

    private func message(uid: UInt32, text: String) -> ScriptMessage {
        ScriptMessage(
            uid: uid, subject: "Verification", from: "sender@example.test",
            internalDate: Date(), envelopeDate: "Thu, 01 Jan 1999 00:00:00 +0000",
            mime: "text/plain", charset: "utf-8", transferEncoding: "7BIT",
            body: Data(text.utf8))
    }
}

private actor JunkEventLog {
    private var messages: [ReceivedMail] = []

    func add(_ event: IMAPFeedEvent) {
        if case .message(let mail) = event { messages.append(mail) }
    }

    func waitForJunk() async throws -> ReceivedMail {
        for _ in 0..<200 {
            if let mail = messages.first(where: \.isFromJunk) { return mail }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ScriptServerError("timed out waiting for junk mail")
    }
}
