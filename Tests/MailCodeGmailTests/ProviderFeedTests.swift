import Foundation
import MailCodeCore
import Testing

@testable import MailCodeGmail

@Suite("MailCodeGmailTests.Providers", .serialized)
struct ProviderFeedTests {
    @Test func netEaseRateLimitStopsRetriesWithFixedMessage() async throws {
        let server = IMAPScriptServer(
            username: "person@163.com", password: "a1b2c3d4e5f6g7h8", loginSucceeds: false,
            loginFailureText: "Connection frequency limited")
        try server.start()
        defer { server.stop() }
        let feed = IMAPAccountFeed(
            configuration: .testing(port: server.port, provider: .neteaseMail, now: Date.init))
        await #expect(throws: GmailIMAPError.rateLimited) {
            try await feed.run(
                login: .init(
                    provider: .neteaseMail, email: "person@163.com", secret: "a1b2c3d4e5f6g7h8")
            ) { _ in }
        }
        #expect(server.acceptedConnectionCount == 1)
        #expect(!GmailIMAPError.rateLimited.localizedDescription.contains("frequency"))
    }

    @Test func codeWaitUsesNoopOnExistingIdleConnections() async throws {
        let email = "person@gmail.com"
        let server = IMAPScriptServer(username: email, password: "abcdefghijklmnop")
        try server.start()
        defer { server.stop() }
        let signal = CodeWaitModeController(duration: .seconds(1))
        let feed = IMAPAccountFeed(
            configuration: .testing(
                port: server.port, now: Date.init, idleRenewal: .seconds(5),
                livenessInterval: .seconds(5)),
            codeWaitSignal: signal)
        let task = Task {
            try await feed.run(
                login: .init(email: email, appPassword: "abcdefghijklmnop")
            ) { _ in }
        }
        defer { task.cancel() }
        try await server.waitUntil { lines in lines.contains { $0.contains(" IDLE") } }
        await signal.begin(.manual)
        try await server.waitUntil { lines in lines.filter { $0.contains(" NOOP") }.count >= 2 }
        let lines = server.commandLog
        #expect(server.acceptedConnectionCount == 2)
        #expect(lines.filter { $0.contains(" EXAMINE") }.count <= 3)
        #expect(!lines.contains { $0.contains(" STATUS ") || $0.contains(" SEARCH ") })
    }

    @Test func codeWaitAcceleratesNoIdleFallbackWithoutNewConnections() async throws {
        let email = "person@qq.com"
        let server = IMAPScriptServer(username: email, password: "qq-secret", capabilities: ["IMAP4rev1"])
        try server.start()
        defer { server.stop() }
        let signal = CodeWaitModeController(duration: .seconds(1))
        let feed = IMAPAccountFeed(
            configuration: .testing(
                port: server.port, provider: .qqMail, now: Date.init,
                pollInterval: .seconds(5)),
            codeWaitSignal: signal)
        let task = Task {
            try await feed.run(
                login: .init(provider: .qqMail, email: email, secret: "qq-secret")
            ) { _ in }
        }
        defer { task.cancel() }
        try await server.waitUntil { lines in lines.contains { $0.contains(" EXAMINE") } }
        await signal.begin(.manual)
        try await server.waitUntil { lines in lines.filter { $0.contains(" NOOP") }.count >= 2 }
        #expect(server.acceptedConnectionCount == 2)
        #expect(!server.commandLog.contains { $0.contains(" STATUS ") || $0.contains(" SEARCH ") })
    }

    @Test func netEaseIdentifiesBeforeEveryExamine() async throws {
        let email = "person@163.com"
        let secret = "a1b2c3d4e5f6g7h8"
        let server = IMAPScriptServer(
            username: email, password: secret, capabilities: ["IMAP4rev1", "ID", "IDLE"])
        try server.start()
        defer { server.stop() }
        let feed = IMAPAccountFeed(
            configuration: .testing(port: server.port, provider: .neteaseMail, now: Date.init))
        let task = Task {
            try await feed.run(login: .init(provider: .neteaseMail, email: email, secret: secret)) { _ in }
        }
        defer { task.cancel() }
        try await server.waitUntil { lines in
            lines.contains { $0.contains(" IDLE") }
                && lines.filter { $0.contains(" EXAMINE") }.count >= 2
        }
        let verbs = server.commandLog.compactMap {
            $0.split(separator: " ").dropFirst().first.map(String.init)
        }
        #expect(verbs.filter { $0 == "ID" }.count == 2)
        #expect(verbs.filter { $0 == "EXAMINE" }.count >= 2)
        #expect(verbs.firstIndex(of: "ID")! < verbs.firstIndex(of: "EXAMINE")!)
        #expect(!verbs.contains("SELECT"))
    }

    @Test func iCloudRetriesFullAddressOnlyAfterLocalNameRejected() async throws {
        let email = "person@me.com"
        let server = IMAPScriptServer(
            username: email, password: "app-password", capabilities: ["IMAP4rev1", "IDLE"])
        try server.start()
        defer { server.stop() }
        let feed = IMAPAccountFeed(
            configuration: .testing(port: server.port, provider: .icloudMail, now: Date.init))
        let task = Task {
            try await feed.run(login: .init(provider: .icloudMail, email: email, secret: "app-password")) {
                _ in
            }
        }
        defer { task.cancel() }
        try await server.waitUntil { lines in lines.contains { $0.contains(" IDLE") } }
        let verbs = server.commandLog.compactMap {
            $0.split(separator: " ").dropFirst().first.map(String.init)
        }
        #expect(verbs.filter { $0 == "LOGIN" }.count >= 3)
        #expect(server.matchedLoginCount == 2)
        #expect(!verbs.contains("ID"))
    }
}
