import Foundation
import MailCodeCore
import Testing

@testable import MailCodeGmail

@Suite("MailCodeGmailTests.Feed", .serialized)
struct GmailIMAPFeedTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func outlookXOAUTH2RefreshesOnceAndRefetchesReadOnly() async throws {
        let server = IMAPScriptServer(
            username: "person@outlook.com", password: "fresh-access", uidValidity: 91,
            messages: [
                message(
                    uid: 4, subject: "Outlook", body: Data("Your verification code is 654321".utf8),
                    age: -10)
            ],
            capabilities: ["IMAP4rev1", "IDLE", "AUTH=XOAUTH2", "SASL-IR"])
        try server.start()
        defer { server.stop() }
        let tokens = FakeMicrosoftTokens()
        let login = try IMAPAccountCredentials.validated(
            provider: .outlook, email: "person@outlook.com", secret: "")
        let log = EventLog()
        let feed = GmailIMAPFeed(
            configuration: configuration(port: server.port, provider: .outlook),
            microsoftTokens: tokens)
        let task = Task { try await feed.run(login: login, onEvent: { log.add($0) }) }
        defer { task.cancel() }
        let mail = try await waitMail(log)
        #expect(mail.id.account == "outlook:person@outlook.com")
        #expect(mail.id.uid == 4)
        #expect(server.matchedXOAUTH2Count >= 2)
        #expect(await tokens.refreshCount == 1)
        task.cancel()
        try await waitCancelled(task)

        let refetcher = GmailMissedMailFetcher(
            host: "127.0.0.1", port: server.port, security: .plainText,
            microsoftTokens: tokens)
        let fetched = try await refetcher.fetchReadOnly(login: login, message: mail.id)
        #expect(fetched.bodies.contains { $0.contains("654321") })
        let commands = server.commandLog.joined(separator: "\n").uppercased()
        #expect(commands.contains("AUTHENTICATE XOAUTH2"))
        #expect(commands.contains("EXAMINE"))
        #expect(commands.contains("BODY.PEEK"))
        for forbidden in ["STORE", "COPY", "DELETE", "EXPUNGE", "APPEND", "SELECT"] {
            #expect(!commands.contains(" \(forbidden)"))
        }
        #expect(!commands.contains("FRESH-ACCESS"))
        #expect(!commands.contains("STALE-ACCESS"))
        #expect(!commands.contains("PERSON@OUTLOOK.COM"))
    }

    @Test func revokedOutlookTokenStopsWithoutBackgroundRetries() async throws {
        let server = IMAPScriptServer(
            username: "person@outlook.com", password: "unused",
            capabilities: ["IMAP4rev1", "AUTH=XOAUTH2", "SASL-IR"])
        try server.start()
        defer { server.stop() }
        let feed = GmailIMAPFeed(
            configuration: configuration(port: server.port, provider: .outlook),
            microsoftTokens: RevokedMicrosoftTokens())
        let login = try IMAPAccountCredentials.validated(
            provider: .outlook, email: "person@outlook.com", secret: "")
        await #expect(throws: MicrosoftOAuthError.needsReauthentication) {
            try await feed.run(login: login, onEvent: { _ in })
        }
        #expect(server.acceptedConnectionCount == 1)
        #expect(server.xoauthAttemptCount == 0)
    }

    @Test func readsRecentPeekMailAndSkipsExpired() async throws {
        let freshBody = Data("verification code is 654321\n".utf8).base64EncodedData()
        let server = IMAPScriptServer(
            username: "person@example.test", password: "abcdefghijklmnop", uidValidity: 11,
            messages: [
                message(
                    uid: 1, subject: "Old", body: Data("verification code is 111111\n".utf8),
                    age: -(CandidateVault.retention + 60)),
                message(
                    uid: 2, subject: "=?UTF-8?B?6aqM6K+B56CB?=",
                    from: "=?UTF-8?B?5rWL6K+V?= <codes@example.test>",
                    body: freshBody, encoding: "BASE64", age: -30),
            ])
        try server.start()
        defer { server.stop() }
        let log = EventLog()
        let feed = GmailIMAPFeed(configuration: configuration(port: server.port))
        let task = Task {
            try await feed.run(login: login, onEvent: { log.add($0) })
        }
        defer { task.cancel() }
        let mail = try await waitMail(log)
        try await log.waitUntil {
            $0.contains {
                if case .state(.listening) = $0 { return true }
                return false
            }
        }
        #expect(mail.id.uid == 2)
        #expect(mail.id.uidValidity == 11)
        #expect(mail.id.mailbox == "INBOX")
        #expect(mail.id.account == "person@example.test")
        #expect(mail.subject == "验证码")
        #expect(mail.sender.contains("测试"))
        #expect(mail.bodies.contains { $0.contains("654321") })
        #expect(mail.receivedAt == now.addingTimeInterval(-30))
        #expect(
            !log.snapshot().contains { event in
                if case .message(let other) = event { return other.bodies.contains { $0.contains("111111") } }
                return false
            })
        let verbs = commandVerbs(server.commandLog)
        #expect(
            server.commandLog.contains { line in
                let upper = line.uppercased()
                return upper.contains("EXAMINE") && upper.contains("INBOX")
            })
        #expect(
            server.commandLog.contains { line in
                let upper = line.uppercased()
                return upper.contains("BODY.PEEK[1]<0.") && upper.contains("65537")
            })
        let events = log.snapshot()
        let connecting = try #require(
            events.firstIndex {
                if case .state(.connecting) = $0 { return true }
                return false
            })
        let synchronizing = try #require(
            events.firstIndex {
                if case .state(.synchronizing) = $0 { return true }
                return false
            })
        let messageIndex = try #require(
            events.firstIndex {
                if case .message = $0 { return true }
                return false
            })
        let listening = try #require(
            events.firstIndex {
                if case .state(.listening) = $0 { return true }
                return false
            })
        #expect(connecting < synchronizing)
        #expect(synchronizing < messageIndex)
        #expect(messageIndex < listening)
        #expect(verbs.filter { $0 == "CAPABILITY" }.count == verbs.filter { $0 == "LOGIN" }.count)
        #expect(verbs.contains("IDLE"))
        #expect(!verbs.contains("SELECT"))
        #expect(
            !server.commandLog.contains { line in
                let upper = line.uppercased()
                return upper.contains("STORE") || upper.contains("APPEND") || upper.contains("EXPUNGE")
                    || upper.contains(" CLOSE")
            })
        #expect(server.matchedLoginCount == 2)
        #expect(!server.commandLog.joined(separator: "\n").contains("abcdefghijklmnop"))
        task.cancel()
        try await waitCancelled(task)
    }

    @Test func authenticationFailureIsTerminal() async throws {
        let server = IMAPScriptServer(
            username: "person@example.test", password: "abcdefghijklmnop", loginSucceeds: false)
        try server.start()
        defer { server.stop() }
        let feed = GmailIMAPFeed(configuration: configuration(port: server.port))
        await #expect(throws: GmailIMAPError.authenticationRejected) {
            try await feed.run(login: login, onEvent: { _ in })
        }
        let description = GmailIMAPError.authenticationRejected.localizedDescription
        #expect(!description.contains("AUTHENTICATIONFAILED"))
        #expect(!description.contains("abcdefghijklmnop"))
        #expect(server.acceptedConnectionCount == 1)
        #expect(!commandVerbs(server.commandLog).contains("EXAMINE"))
    }

    @Test func missingIdleFailsWithoutPolling() async throws {
        let server = IMAPScriptServer(
            username: "person@example.test", password: "abcdefghijklmnop",
            capabilities: ["IMAP4rev1"])
        try server.start()
        defer { server.stop() }
        let feed = GmailIMAPFeed(configuration: configuration(port: server.port))
        await #expect(throws: GmailIMAPError.idleUnavailable) {
            try await feed.run(login: login, onEvent: { _ in })
        }
        let verbs = commandVerbs(server.commandLog)
        #expect(!verbs.contains("IDLE"))
        #expect(!verbs.contains("NOOP"))
        #expect(!verbs.contains("FETCH"))
        #expect(verbs.filter { $0 == "CAPABILITY" }.count == verbs.filter { $0 == "LOGIN" }.count + 1)
        #expect(server.acceptedConnectionCount == 2)
    }

    @Test func qqMailUsesAdvertisedIdleAndKeepsMailboxIdentityAndDates() async throws {
        let server = IMAPScriptServer(
            username: "person@qq.com", password: "test-authorization-code", uidValidity: 73,
            messages: [
                message(
                    uid: 8, subject: "QQ login", from: "QQ Mail <notice@qq.com>",
                    body: Data("Your verification code is 123456".utf8), age: -27)
            ])
        try server.start()
        defer { server.stop() }
        let login = try IMAPAccountCredentials.validated(
            provider: .qqMail, email: "person@qq.com", secret: "test-authorization-code")
        let log = EventLog()
        let feed = GmailIMAPFeed(configuration: configuration(port: server.port, provider: .qqMail))
        let task = Task { try await feed.run(login: login, onEvent: { log.add($0) }) }
        defer { task.cancel() }
        let mail = try await waitMail(log)
        try await log.waitUntil { $0.contains { if case .state(.listening) = $0 { true } else { false } } }
        #expect(mail.id.account == "qq:person@qq.com")
        #expect(mail.id.uidValidity == 73)
        #expect(mail.id.uid == 8)
        #expect(mail.receivedAt == now.addingTimeInterval(-27))
        #expect(commandVerbs(server.commandLog).contains("IDLE"))
        #expect(!server.commandLog.joined(separator: "\n").contains("test-authorization-code"))
        task.cancel()
        try await waitCancelled(task)
    }

    @Test func qqMailWithoutIdleUsesCancellableTenSecondPollPath() async throws {
        let server = IMAPScriptServer(
            username: "person@qq.com", password: "synthetic-qq-code", uidValidity: 74,
            messages: [
                message(
                    uid: 1, subject: "QQ first", from: "QQ Mail <notice@qq.com>",
                    body: Data("Your verification code is 654321".utf8), age: -14)
            ],
            capabilities: ["IMAP4rev1"])
        try server.start()
        defer { server.stop() }
        let login = try IMAPAccountCredentials.validated(
            provider: .qqMail, email: "person@qq.com", secret: "synthetic-qq-code")
        let log = EventLog()
        let feed = GmailIMAPFeed(
            configuration: configuration(
                port: server.port, provider: .qqMail, pollInterval: .milliseconds(60)))
        let task = Task { try await feed.run(login: login, onEvent: { log.add($0) }) }
        defer { task.cancel() }
        try await log.waitUntil { events in
            events.contains { if case .state(.polling) = $0 { true } else { false } }
                && events.contains { if case .message = $0 { true } else { false } }
        }
        let first = try #require(log.mails.first)
        #expect(first.id.account == "qq:person@qq.com")
        #expect(first.id.uidValidity == 74)
        #expect(first.receivedAt == now.addingTimeInterval(-14))
        server.store(
            message(
                uid: 2, subject: "QQ second", from: "QQ Mail <notice@qq.com>",
                body: Data("Your verification code is 001234".utf8), age: -8))
        try await log.waitUntil {
            $0.contains { if case .message(let mail) = $0 { mail.id.uid == 2 } else { false } }
        }
        #expect(log.mails.first { $0.id.uid == 2 }?.receivedAt == now.addingTimeInterval(-8))
        #expect(commandVerbs(server.commandLog).contains("NOOP"))
        #expect(!commandVerbs(server.commandLog).contains("IDLE"))
        task.cancel()
        try await waitCancelled(task)
    }

    @Test func writableExamineIsRefused() async throws {
        let server = IMAPScriptServer(
            username: "person@example.test", password: "abcdefghijklmnop", examineReadOnly: false)
        try server.start()
        defer { server.stop() }
        let feed = GmailIMAPFeed(configuration: configuration(port: server.port))
        await #expect(throws: GmailIMAPError.mailboxNotReadOnly) {
            try await feed.run(login: login, onEvent: { _ in })
        }
        #expect(!server.commandLog.contains { $0.uppercased().contains("BODY.PEEK") })
    }

    @Test func emptyMailboxIsListening() async throws {
        let server = IMAPScriptServer(username: "person@example.test", password: "abcdefghijklmnop")
        try server.start()
        defer { server.stop() }
        let log = EventLog()
        let feed = GmailIMAPFeed(configuration: configuration(port: server.port))
        let task = Task { try await feed.run(login: login, onEvent: { log.add($0) }) }
        defer { task.cancel() }
        try await log.waitUntil {
            $0.contains {
                if case .state(.listening) = $0 { return true }
                return false
            }
        }
        #expect(
            !log.snapshot().contains {
                if case .message = $0 { return true }
                return false
            })
        task.cancel()
        try await waitCancelled(task)
    }

    @Test func undecodableBodyIsANotice() async throws {
        let server = IMAPScriptServer(
            username: "person@example.test", password: "abcdefghijklmnop",
            messages: [
                message(uid: 3, subject: "Broken", body: Data([0xFF, 0xFE]), encoding: "7BIT", age: -10)
            ])
        try server.start()
        defer { server.stop() }
        let log = EventLog()
        let feed = GmailIMAPFeed(configuration: configuration(port: server.port))
        let task = Task { try await feed.run(login: login, onEvent: { log.add($0) }) }
        defer { task.cancel() }
        try await log.waitUntil { events in
            events.contains {
                if case .notice(GmailNotice.undecodable) = $0 { return true }
                return false
            }
                && events.contains {
                    if case .state(.listening) = $0 { return true }
                    return false
                }
        }
        #expect(
            !log.snapshot().contains {
                if case .message = $0 { return true }
                return false
            })
    }

    @Test func limitedWindowReportsIncompleteCatchup() async throws {
        let server = IMAPScriptServer(
            username: "person@example.test", password: "abcdefghijklmnop",
            messages: [
                message(uid: 1, subject: "First", body: Data("verification code is 121212\n".utf8), age: -20),
                message(
                    uid: 2, subject: "Second", body: Data("verification code is 343434\n".utf8), age: -10),
            ])
        try server.start()
        defer { server.stop() }
        let log = EventLog()
        let feed = GmailIMAPFeed(configuration: configuration(port: server.port, catchupLimit: 1))
        let task = Task { try await feed.run(login: login, onEvent: { log.add($0) }) }
        defer { task.cancel() }
        try await log.waitUntil { events in
            events.contains {
                if case .notice(GmailNotice.incomplete) = $0 { return true }
                return false
            }
                && events.contains {
                    if case .message = $0 { return true }
                    return false
                }
        }
        #expect(log.mails.map(\.id.uid) == [2])
        #expect(!log.mails.contains { $0.bodies.contains { $0.contains("121212") } })
    }

    @Test func cancellationClosesIdleAndBackoff() async throws {
        let server = IMAPScriptServer(username: "person@example.test", password: "abcdefghijklmnop")
        try server.start()
        defer { server.stop() }
        let log = EventLog()
        let feed = GmailIMAPFeed(
            configuration: configuration(
                port: server.port, idleRenewal: .seconds(30), backoff: [.seconds(30)]))
        let started = ContinuousClock.now
        let task = Task { try await feed.run(login: login, onEvent: { log.add($0) }) }
        try await log.waitUntil {
            $0.contains {
                if case .state(.listening) = $0 { return true }
                return false
            }
        }
        task.cancel()
        try await waitCancelled(task)
        #expect(ContinuousClock.now - started < .seconds(5))

        let again = EventLog()
        let retry = GmailIMAPFeed(
            configuration: configuration(
                port: server.port, idleRenewal: .seconds(30), backoff: [.seconds(30)]))
        let retryTask = Task { try await retry.run(login: login, onEvent: { again.add($0) }) }
        try await again.waitUntil {
            $0.contains {
                if case .state(.listening) = $0 { return true }
                return false
            }
        }
        let dropped = ContinuousClock.now
        server.dropClients()
        try await again.waitUntil {
            $0.contains {
                if case .state(.reconnecting) = $0 { return true }
                return false
            }
        }
        retryTask.cancel()
        try await waitCancelled(retryTask)
        #expect(ContinuousClock.now - dropped < .seconds(5))
    }

    @Test func reconnectResetsValidityAndDoesNotReviveExpiredMail() async throws {
        let server = IMAPScriptServer(
            username: "person@example.test", password: "abcdefghijklmnop", uidValidity: 11,
            messages: [
                message(uid: 2, subject: "Fresh", body: Data("verification code is 654321\n".utf8), age: -20)
            ])
        try server.start()
        defer { server.stop() }
        let log = EventLog()
        let feed = GmailIMAPFeed(
            configuration: configuration(
                port: server.port, idleRenewal: .seconds(30), backoff: [.milliseconds(40)]))
        let task = Task { try await feed.run(login: login, onEvent: { log.add($0) }) }
        defer { task.cancel() }
        _ = try await waitMail(log)
        server.replaceMailbox(
            uidValidity: 22,
            messages: [
                message(
                    uid: 2, subject: "Stale", body: Data("verification code is 111111\n".utf8),
                    age: -(CandidateVault.retention + 30)),
                message(
                    uid: 1, subject: "Recycled", body: Data("verification code is 777888\n".utf8), age: -15),
            ])
        server.dropClients()
        try await log.waitUntil { events in
            events.contains { event in
                if case .message(let mail) = event { return mail.id.uid == 1 && mail.id.uidValidity == 22 }
                return false
            }
        }
        #expect(
            log.mails.contains { $0.bodies.contains { $0.contains("777888") } && $0.id.uidValidity == 22 })
        #expect(!log.mails.contains { $0.bodies.contains { $0.contains("111111") } })
    }

    @Test func idleRenewalSendsAnotherIdle() async throws {
        let server = IMAPScriptServer(username: "person@example.test", password: "abcdefghijklmnop")
        try server.start()
        defer { server.stop() }
        let feed = GmailIMAPFeed(
            configuration: configuration(
                port: server.port, idleRenewal: .milliseconds(200)))
        let task = Task { try await feed.run(login: login, onEvent: { _ in }) }
        defer { task.cancel() }
        try await server.waitUntil { lines in
            lines.filter { $0.uppercased().contains("IDLE") }.count >= 2
        }
    }

    @Test func livenessNoopFetchesMailWhenIdlePushIsMissed() async throws {
        let server = IMAPScriptServer(username: "person@example.test", password: "abcdefghijklmnop")
        try server.start()
        defer { server.stop() }
        let log = EventLog()
        let feed = GmailIMAPFeed(
            configuration: configuration(
                port: server.port, idleRenewal: .seconds(30), livenessInterval: .milliseconds(100)))
        let task = Task { try await feed.run(login: login, onEvent: { log.add($0) }) }
        defer { task.cancel() }
        try await log.waitUntil {
            $0.contains { if case .state(.listening) = $0 { true } else { false } }
        }

        server.store(
            message(uid: 6, subject: "Quiet", body: Data("verification code is 606060\n".utf8), age: -5))
        try await log.waitUntil {
            $0.contains { event in
                if case .message(let mail) = event { return mail.id.uid == 6 }
                return false
            }
        }
        #expect(log.mails.filter { $0.id.uid == 6 }.count == 1)
        #expect(commandVerbs(server.commandLog).contains("NOOP"))
    }

    @Test func silentNoopReconnectsWithoutFinOrRst() async throws {
        let server = IMAPScriptServer(
            username: "person@example.test", password: "abcdefghijklmnop", silenceNoop: true)
        try server.start()
        defer { server.stop() }
        let log = EventLog()
        let feed = GmailIMAPFeed(
            configuration: configuration(
                port: server.port, idleRenewal: .seconds(30), livenessInterval: .milliseconds(100)))
        let started = ContinuousClock.now
        let task = Task { try await feed.run(login: login, onEvent: { log.add($0) }) }
        defer { task.cancel() }
        try await log.waitUntil(timeout: .seconds(8)) {
            $0.contains { if case .state(.reconnecting) = $0 { true } else { false } }
        }
        try await server.waitUntil(timeout: .seconds(3)) { lines in
            lines.filter { $0.contains("LOGIN <redacted>") }.count >= 4
        }
        #expect(ContinuousClock.now - started < .seconds(8))
        #expect(server.commandLog.contains { $0.uppercased().contains("NOOP") })
    }

    @Test func reconnectCatchupDoesNotDuplicateCandidate() async throws {
        let receivedAt = Date().addingTimeInterval(-5)
        let server = IMAPScriptServer(
            username: "person@example.test", password: "abcdefghijklmnop",
            messages: [
                ScriptMessage(
                    uid: 3, subject: "Login", from: "codes@example.test", internalDate: receivedAt,
                    envelopeDate: "Thu, 01 Jan 1999 00:00:00 +0000", mime: "text/plain",
                    charset: "utf-8", transferEncoding: "7BIT",
                    body: Data("Your verification code is 424242".utf8))
            ])
        try server.start()
        defer { server.stop() }
        let vault = CandidateVault()
        let account = IMAPAccount(provider: .gmail, email: "person@example.test")
        let credentialStore = FeedTestCredentialStore()
        let suite = "MailCodeFiller.feed-reconnect.\(UUID())"
        let preferences = try FeedTestPreferences(suite: suite)
        defer { preferences.clear() }
        let feed = GmailIMAPFeed(
            configuration: configuration(
                port: server.port, idleRenewal: .seconds(30), now: { Date() }))
        let session = try await MainActor.run { () throws -> GmailSession in
            let session = GmailSession(
                account: account, vault: vault, feed: feed, credentials: credentialStore,
                preferences: preferences.defaults)
            try session.connect(secret: login.appPassword)
            return session
        }

        let initial = try await waitForCandidate(vault)
        let initialFetches = server.commandLog.filter { $0.uppercased().contains("BODY.PEEK") }.count
        server.dropClients()
        try await server.waitUntil(timeout: .seconds(6)) { lines in
            lines.filter { $0.contains("LOGIN <redacted>") }.count >= 4
                && lines.filter { $0.uppercased().contains("BODY.PEEK") }.count > initialFetches
        }
        try await Task.sleep(for: .milliseconds(100))
        let afterReconnect = await vault.snapshot(now: Date())
        #expect(initial.count == 1)
        #expect(afterReconnect.count == 1)
        #expect(afterReconnect.first?.id == initial.first?.id)
        await session.pause()
    }

    @Test func callbackBackpressureKeepsOrder() async throws {
        let server = IMAPScriptServer(
            username: "person@example.test", password: "abcdefghijklmnop",
            messages: [
                message(uid: 5, subject: "Held", body: Data("verification code is 909090\n".utf8), age: -5)
            ])
        try server.start()
        defer { server.stop() }
        let log = EventLog()
        let gate = ResumeGate()
        let feed = GmailIMAPFeed(configuration: configuration(port: server.port))
        let task = Task {
            try await feed.run(
                login: login,
                onEvent: { event in
                    log.add(event)
                    if case .state(.synchronizing) = event { await gate.wait() }
                })
        }
        defer { task.cancel() }
        try await log.waitUntil {
            $0.contains {
                if case .state(.synchronizing) = $0 { return true }
                return false
            }
        }
        #expect(log.mails.isEmpty)
        #expect(!log.states.contains(.listening))
        gate.release()
        _ = try await waitMail(log)
        try await log.waitUntil {
            $0.contains {
                if case .state(.listening) = $0 { return true }
                return false
            }
        }
    }

    @Test func partialPeekSkipsBodiesPastTheCap() async throws {
        let server = IMAPScriptServer(
            username: "person@example.test", password: "abcdefghijklmnop",
            messages: [
                message(
                    uid: 8, subject: "Huge",
                    body: Data(repeating: 0x41, count: 40), age: -5, declaredOctets: 8)
            ])
        try server.start()
        defer { server.stop() }
        let log = EventLog()
        let feed = GmailIMAPFeed(configuration: configuration(port: server.port, maxBodyBytes: 16))
        let task = Task { try await feed.run(login: login, onEvent: { log.add($0) }) }
        defer { task.cancel() }
        try await log.waitUntil {
            $0.contains {
                if case .notice(GmailNotice.oversized) = $0 { return true }
                return false
            }
                && $0.contains {
                    if case .state(.listening) = $0 { return true }
                    return false
                }
        }
        #expect(server.commandLog.contains { $0.contains("BODY.PEEK[1]<0.17>") })
        #expect(server.acceptedConnectionCount == 2)
        #expect(server.matchedLoginCount == 2)
        #expect(log.mails.isEmpty)
    }

    @Test func ordinaryFetchFailureStaysRetryable() async throws {
        let server = IMAPScriptServer(
            username: "person@example.test", password: "abcdefghijklmnop",
            messages: [
                message(uid: 4, subject: "Retry", body: Data("verification code is 454545\n".utf8), age: -5)
            ], rejectBodyFetch: true)
        try server.start()
        defer { server.stop() }
        let log = EventLog()
        let feed = GmailIMAPFeed(
            configuration: configuration(port: server.port, backoff: [.milliseconds(40)]))
        let task = Task { try await feed.run(login: login, onEvent: { log.add($0) }) }
        defer { task.cancel() }
        try await server.waitUntil { lines in lines.filter { $0.contains("LOGIN") }.count >= 3 }
        #expect(!log.notices.contains(GmailNotice.oversized))
        #expect(log.states.contains(.reconnecting))
    }

    @Test func newestMailIsDeliveredBeforeOlderCatchupBodies() async throws {
        let server = IMAPScriptServer(
            username: "person@example.test", password: "abcdefghijklmnop",
            messages: [
                message(uid: 1, subject: "Older", body: Data("verification code is 111222".utf8), age: -20),
                message(uid: 2, subject: "Newest", body: Data("verification code is 333444".utf8), age: -1),
            ])
        try server.start()
        defer { server.stop() }
        let log = EventLog()
        let feed = GmailIMAPFeed(configuration: configuration(port: server.port))
        let task = Task { try await feed.run(login: login, onEvent: { log.add($0) }) }
        defer { task.cancel() }
        let first = try await waitMail(log)
        #expect(first.id.uid == 2)
        #expect(first.fetchMilliseconds != nil)
        try await log.waitUntil { events in
            events.contains {
                if case .message(let mail) = $0 { return mail.id.uid == 1 }
                return false
            }
        }
        let bodies = server.commandLog.filter { $0.contains("BODY.PEEK") }
        #expect(bodies.first?.contains("UID FETCH 2") == true)
        task.cancel()
        try await waitCancelled(task)
    }

    @Test func mailArrivingDuringCatchupIsFetched() async throws {
        let server = IMAPScriptServer(
            username: "person@example.test", password: "abcdefghijklmnop",
            messages: [
                message(uid: 1, subject: "First", body: Data("verification code is 111222\n".utf8), age: -20)
            ], loginOmitsIdle: true)
        try server.start()
        defer { server.stop() }
        let log = EventLog()
        let feed = GmailIMAPFeed(configuration: configuration(port: server.port))
        let task = Task {
            try await feed.run(
                login: login,
                onEvent: { event in
                    log.add(event)
                    if case .message(let mail) = event, mail.id.uid == 1 {
                        server.append(
                            message(
                                uid: 2, subject: "Second",
                                body: Data("verification code is 333444\n".utf8), age: -5))
                    }
                })
        }
        defer { task.cancel() }
        try await log.waitUntil { events in
            events.contains { event in
                if case .message(let mail) = event { return mail.id.uid == 2 }
                return false
            }
        }
        #expect(log.mails.map(\.id.uid).contains(1))
        #expect(log.mails.map(\.id.uid).contains(2))
        let verbs = commandVerbs(server.commandLog)
        let idle = try #require(verbs.firstIndex(of: "IDLE"))
        let fetch = try #require(verbs.firstIndex(of: "FETCH"))
        #expect(idle < fetch)
        #expect(!verbs.contains("SELECT"))
        #expect(verbs.filter { $0 == "CAPABILITY" }.count == verbs.filter { $0 == "LOGIN" }.count + 1)
    }

    @Test func catchupActivityDoesNotPostponeIdleRenewal() async throws {
        let server = IMAPScriptServer(
            username: "person@example.test", password: "abcdefghijklmnop",
            messages: [message(uid: 1, subject: "First", body: Data("code: 111222".utf8), age: -20)])
        try server.start()
        defer { server.stop() }
        let log = EventLog()
        let feed = GmailIMAPFeed(
            configuration: configuration(port: server.port, idleRenewal: .milliseconds(100)))
        let task = Task {
            try await feed.run(login: login) { event in
                log.add(event)
                if case .message(let mail) = event, mail.id.uid == 1 {
                    // Simulate a callback lasting past the protocol renewal deadline.
                    try? await Task.sleep(for: .milliseconds(200))
                    server.append(message(uid: 2, subject: "Next", body: Data("code: 333444".utf8), age: -5))
                }
            }
        }
        defer { task.cancel() }
        try await log.waitUntil { events in
            events.contains {
                if case .message(let mail) = $0 { return mail.id.uid == 2 }
                return false
            }
        }
        let commands = server.commandLog
        let renewed = try #require(commands.firstIndex(of: "DONE"))
        let secondFetch = try #require(commands.firstIndex { $0.contains("UID FETCH 2") })
        #expect(renewed < secondFetch)
        #expect(commandVerbs(commands).filter { $0 == "IDLE" }.count >= 2)
        task.cancel()
        try await waitCancelled(task)
    }

    @Test func mailArrivingWhileListeningIsFetched() async throws {
        let server = IMAPScriptServer(username: "person@example.test", password: "abcdefghijklmnop")
        try server.start()
        defer { server.stop() }
        let log = EventLog()
        let feed = GmailIMAPFeed(
            configuration: configuration(port: server.port, idleRenewal: .seconds(30)))
        let task = Task { try await feed.run(login: login, onEvent: { log.add($0) }) }
        defer { task.cancel() }
        try await log.waitUntil {
            $0.contains {
                if case .state(.listening) = $0 { return true }
                return false
            }
        }
        server.append(
            message(uid: 4, subject: "Live", body: Data("verification code is 808080\n".utf8), age: -5))
        try await log.waitUntil {
            $0.contains { event in
                if case .message(let mail) = event { return mail.id.uid == 4 }
                return false
            }
        }
        #expect(log.mails.contains { $0.bodies.contains { $0.contains("808080") } })
    }

    @Test func missedIdlePushIsFetchedOnRenewal() async throws {
        let server = IMAPScriptServer(username: "person@example.test", password: "abcdefghijklmnop")
        try server.start()
        defer { server.stop() }
        let log = EventLog()
        let feed = GmailIMAPFeed(
            configuration: configuration(port: server.port, idleRenewal: .milliseconds(200)))
        let task = Task { try await feed.run(login: login, onEvent: { log.add($0) }) }
        defer { task.cancel() }
        try await log.waitUntil {
            $0.contains {
                if case .state(.listening) = $0 { return true }
                return false
            }
        }
        server.store(
            message(uid: 6, subject: "Quiet", body: Data("verification code is 606060\n".utf8), age: -5))
        try await log.waitUntil {
            $0.contains { event in
                if case .message(let mail) = event { return mail.id.uid == 6 }
                return false
            }
        }
        #expect(log.mails.contains { $0.bodies.contains { $0.contains("606060") } })
    }

    @Test(arguments: [false, true])
    func htmlCodeIsDeliveredWhenPlainIsUnavailable(corruptPlain: Bool) async throws {
        let plain = corruptPlain ? Data([0xFF, 0xFE]) : Data("Open the HTML version.\n".utf8)
        let server = IMAPScriptServer(
            username: "person@example.test", password: "abcdefghijklmnop",
            messages: [
                message(
                    uid: 7, subject: "Login", body: plain, age: -10,
                    htmlBody: Data("<p>verification code is 246810</p>".utf8))
            ])
        try server.start()
        defer { server.stop() }
        let log = EventLog()
        let feed = GmailIMAPFeed(configuration: configuration(port: server.port))
        let task = Task { try await feed.run(login: login, onEvent: { log.add($0) }) }
        defer { task.cancel() }
        let mail = try await waitMail(log)
        let cap = 64 * 1024
        #expect(mail.bodies.count == (corruptPlain ? 1 : 2))
        #expect(mail.bodies.contains { $0.contains("246810") })
        let warned = log.snapshot().contains {
            if case .notice(GmailNotice.partialDecode) = $0 { return true }
            return false
        }
        #expect(warned == corruptPlain)
        #expect(server.commandLog.contains { $0.contains("BODY.PEEK[1]<0.\(cap + 1)>") })
        #expect(server.commandLog.contains { $0.contains("BODY.PEEK[2]<0.\(cap - plain.count + 1)>") })
    }

    @Test func bothPartsRemainSeparateAndCoreDeduplicates() async throws {
        let server = IMAPScriptServer(
            username: "person@example.test", password: "abcdefghijklmnop",
            messages: [
                message(
                    uid: 8, subject: "Login",
                    body: Data("verification code is 135790\n".utf8), age: -10,
                    htmlBody: Data(
                        "<p>verification code is 135790</p><p>verification code is 999999</p>".utf8))
            ])
        try server.start()
        defer { server.stop() }
        let log = EventLog()
        let feed = GmailIMAPFeed(configuration: configuration(port: server.port))
        let task = Task { try await feed.run(login: login, onEvent: { log.add($0) }) }
        defer { task.cancel() }
        let mail = try await waitMail(log)
        #expect(
            mail.bodies.map { CodeDetector().codes(subject: mail.subject, body: $0) }
                == [["135790"], ["135790", "999999"]])
        #expect(CodeDetector().codes(subject: mail.subject, bodies: mail.bodies) == ["135790", "999999"])
        #expect(server.commandLog.contains { $0.contains("BODY.PEEK[1]<") })
        #expect(server.commandLog.contains { $0.contains("BODY.PEEK[2]<") })
    }

    @Test func sharedBodyBudgetSkipsBothPartsWhenTheirSizesExceedIt() async throws {
        let plain = Data(repeating: 0x41, count: 20)
        let html = Data(repeating: 0x42, count: 20)
        let server = IMAPScriptServer(
            username: "person@example.test", password: "abcdefghijklmnop",
            messages: [
                message(uid: 9, subject: "Wide", body: plain, age: -5, htmlBody: html)
            ])
        try server.start()
        defer { server.stop() }
        let log = EventLog()
        let feed = GmailIMAPFeed(configuration: configuration(port: server.port, maxBodyBytes: 30))
        let task = Task { try await feed.run(login: login, onEvent: { log.add($0) }) }
        defer { task.cancel() }
        try await log.waitUntil {
            $0.contains {
                if case .notice(GmailNotice.oversized) = $0 { return true }
                return false
            }
                && $0.contains {
                    if case .state(.listening) = $0 { return true }
                    return false
                }
        }
        #expect(log.mails.isEmpty)
        #expect(!server.commandLog.contains { $0.contains("BODY.PEEK") })
    }

    @Test func futureInternalDateIsFetchedAfterTheClockCatchesUp() async throws {
        let clock = MutableClock(now)
        let server = IMAPScriptServer(
            username: "person@example.test", password: "abcdefghijklmnop",
            messages: [
                message(
                    uid: 12, subject: "Early", body: Data("verification code is 121314\n".utf8),
                    age: 10 * 60)
            ])
        try server.start()
        defer { server.stop() }
        let log = EventLog()
        let feed = GmailIMAPFeed(
            configuration: configuration(
                port: server.port, idleRenewal: .milliseconds(200), now: { clock.now() }))
        let task = Task { try await feed.run(login: login, onEvent: { log.add($0) }) }
        defer { task.cancel() }
        try await log.waitUntil {
            $0.contains {
                if case .state(.listening) = $0 { return true }
                return false
            }
        }
        #expect(log.mails.isEmpty)
        #expect(log.notices.contains(GmailNotice.futureDate))
        #expect(!log.notices.contains(GmailNotice.unusableDate))
        clock.advance(11 * 60)
        try await log.waitUntil {
            $0.contains { event in
                if case .message(let mail) = event { return mail.bodies.contains { $0.contains("121314") } }
                return false
            }
        }
    }

    @Test func reconnectFetchesTheSameFreshMessageAgain() async throws {
        let server = IMAPScriptServer(
            username: "person@example.test", password: "abcdefghijklmnop", uidValidity: 11,
            messages: [
                message(uid: 3, subject: "Fresh", body: Data("verification code is 414141\n".utf8), age: -15)
            ])
        try server.start()
        defer { server.stop() }
        let log = EventLog()
        let feed = GmailIMAPFeed(
            configuration: configuration(port: server.port, backoff: [.milliseconds(40)]))
        let task = Task { try await feed.run(login: login, onEvent: { log.add($0) }) }
        defer { task.cancel() }
        _ = try await waitMail(log)
        server.dropClients()
        try await log.waitUntil { logEvents in
            logEvents.compactMap { event -> UInt32? in
                if case .message(let mail) = event, mail.id.uidValidity == 11 { return mail.id.uid }
                return nil
            }.filter { $0 == 3 }.count >= 2
        }
        #expect(log.mails.filter { $0.bodies.contains { $0.contains("414141") } }.count >= 2)
    }

    @Test func doneFailureReconnects() async throws {
        let server = IMAPScriptServer(
            username: "person@example.test", password: "abcdefghijklmnop", rejectDone: true)
        try server.start()
        defer { server.stop() }
        let log = EventLog()
        let feed = GmailIMAPFeed(
            configuration: configuration(
                port: server.port, idleRenewal: .milliseconds(200), backoff: [.milliseconds(40)]))
        let task = Task { try await feed.run(login: login, onEvent: { log.add($0) }) }
        defer { task.cancel() }
        try await server.waitUntil { lines in lines.filter { $0.contains("LOGIN") }.count >= 3 }
        #expect(log.states.contains(.reconnecting))
    }

    private var login: GmailLogin {
        GmailLogin(email: " person@example.test ", appPassword: "abcd efgh ijkl mnop")
    }

    private func configuration(
        port: Int,
        provider: IMAPProvider = .gmail,
        catchupLimit: Int = 30,
        maxBodyBytes: Int = 64 * 1024,
        idleRenewal: Duration = .seconds(30),
        livenessInterval: Duration = .seconds(60),
        pollInterval: Duration = .milliseconds(100),
        backoff: [Duration] = [.milliseconds(40)],
        now: (@Sendable () -> Date)? = nil
    ) -> GmailIMAPConfiguration {
        let frozen = self.now
        return .testing(
            port: port, provider: provider, now: now ?? { frozen }, catchupLimit: catchupLimit,
            maxBodyBytes: maxBodyBytes, idleRenewal: idleRenewal,
            livenessInterval: livenessInterval,
            pollInterval: pollInterval, backoff: backoff)
    }

    private func message(
        uid: UInt32, subject: String, from: String = "codes@example.test",
        body: Data, encoding: String = "7BIT", age: TimeInterval, declaredOctets: Int? = nil,
        htmlBody: Data? = nil
    ) -> ScriptMessage {
        ScriptMessage(
            uid: uid, subject: subject, from: from, internalDate: now.addingTimeInterval(age),
            envelopeDate: "Thu, 01 Jan 1999 00:00:00 +0000", mime: "text/plain", charset: "utf-8",
            transferEncoding: encoding, body: body, htmlBody: htmlBody,
            declaredOctets: declaredOctets)
    }

    private func commandVerbs(_ lines: [String]) -> [String] {
        lines.compactMap { line in
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { return line == "DONE" ? "DONE" : nil }
            return parts[1].uppercased()
        }
    }

    private func waitMail(_ log: EventLog) async throws -> ReceivedMail {
        try await log.waitUntil {
            $0.contains {
                if case .message = $0 { return true }
                return false
            }
        }
        return try #require(log.mails.first)
    }

    private func waitForCandidate(_ vault: CandidateVault) async throws -> [Candidate] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            let candidates = await vault.snapshot(now: Date())
            if !candidates.isEmpty { return candidates }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ScriptServerError("timed out waiting for candidate")
    }

    private func waitCancelled(_ task: Task<Void, Error>) async throws {
        let outcome = await withTaskGroup(of: Result<Void, Error>?.self) { group in
            group.addTask { await task.result }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        switch outcome {
        case .success:
            Issue.record("feed returned without cancellation")
        case .failure(let error):
            #expect(error is CancellationError)
        case nil:
            task.cancel()
            Issue.record("cancellation did not finish the feed")
        }
    }
}

private actor FakeMicrosoftTokens: MicrosoftAccessTokenProviding {
    private(set) var refreshCount = 0

    func accessToken(accountID: String, forceRefresh: Bool) async throws -> String {
        #expect(accountID == "outlook:person@outlook.com")
        if forceRefresh {
            refreshCount += 1
            return "fresh-access"
        }
        return refreshCount == 0 ? "stale-access" : "fresh-access"
    }
}

private actor RevokedMicrosoftTokens: MicrosoftAccessTokenProviding {
    func accessToken(accountID: String, forceRefresh: Bool) async throws -> String {
        throw MicrosoftOAuthError.needsReauthentication
    }
}

private final class FeedTestCredentialStore: IMAPAccountCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: IMAPAccountCredentials] = [:]

    func load(accountID: String) throws -> IMAPAccountCredentials? {
        lock.withLock { values[accountID] }
    }

    func save(_ credentials: IMAPAccountCredentials, accountID: String) throws {
        lock.withLock { values[accountID] = credentials }
    }

    func remove(accountID: String) throws {
        lock.withLock { values[accountID] = nil }
    }
}

private final class FeedTestPreferences: @unchecked Sendable {
    let suite: String
    let defaults: UserDefaults

    init(suite: String) throws {
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ScriptServerError("failed to create test preferences")
        }
        self.suite = suite
        self.defaults = defaults
    }

    func clear() {
        defaults.removePersistentDomain(forName: suite)
    }
}

final class SignalGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false

    func register(_ continuation: CheckedContinuation<Void, Never>, ready: Bool) {
        lock.lock()
        if resumed || ready {
            resumed = true
            lock.unlock()
            continuation.resume()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume() {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        resumed = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

func waitForSignal(
    timeout: Duration,
    isSatisfied: @escaping @Sendable () -> Bool,
    park: @escaping @Sendable () async -> Void
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !isSatisfied() {
        let remaining = deadline - clock.now
        if remaining <= .zero { throw ScriptServerError("timed out waiting for feed") }
        let ready = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                try? await Task.sleep(for: remaining)
                return false
            }
            group.addTask {
                await park()
                return true
            }
            let first = await group.next() ?? false
            group.cancelAll()
            while await group.next() != nil {}
            return first
        }
        if !ready { throw ScriptServerError("timed out waiting for feed") }
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [GmailFeedEvent] = []
    private var waiters: [SignalGate] = []

    func add(_ event: GmailFeedEvent) {
        lock.lock()
        events.append(event)
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }

    func waitUntil(
        timeout: Duration = .seconds(8),
        _ predicate: @escaping @Sendable ([GmailFeedEvent]) -> Bool
    ) async throws {
        try await waitForSignal(
            timeout: timeout, isSatisfied: { predicate(self.snapshot()) },
            park: { await self.park(predicate) }
        )
    }

    private func park(_ predicate: @escaping @Sendable ([GmailFeedEvent]) -> Bool) async {
        let gate = SignalGate()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                let ready = predicate(events)
                if !ready { waiters.append(gate) }
                lock.unlock()
                gate.register(continuation, ready: ready)
            }
        } onCancel: {
            gate.resume()
            lock.lock()
            waiters.removeAll { $0 === gate }
            lock.unlock()
        }
    }

    func snapshot() -> [GmailFeedEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    var states: [GmailFeedState] {
        snapshot().compactMap {
            if case .state(let state) = $0 { return state }
            return nil
        }
    }

    var notices: [String] {
        snapshot().compactMap {
            if case .notice(let text) = $0 { return text }
            return nil
        }
    }

    var mails: [ReceivedMail] {
        snapshot().compactMap {
            if case .message(let mail) = $0 { return mail }
            return nil
        }
    }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ date: Date) { value = date }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ interval: TimeInterval) {
        lock.lock()
        value.addTimeInterval(interval)
        lock.unlock()
    }
}

private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var open = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if open {
                lock.unlock()
                continuation.resume()
                return
            }
            waiting.append(continuation)
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        open = true
        let pending = waiting
        waiting.removeAll()
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }
}
