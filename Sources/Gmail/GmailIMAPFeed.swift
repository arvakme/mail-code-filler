import Foundation
import MailCodeCore
import OSLog
import SwiftMail
import Synchronization

/// Provider-neutral read-only IMAP feed. IDLE providers keep a watcher beside the
/// catchup connection; QQ Mail can use a cancellable bounded poll if IDLE is absent.
public final class IMAPAccountFeed: IMAPFeed, @unchecked Sendable {
    private static let logger = Logger(subsystem: "dev.zhijie.MailCodeFiller", category: "imap")
    private let configuration: IMAPFeedConfiguration
    private let codeWaitSignal: (any CodeWaitSignal)?
    private let active = Mutex<IMAPServer?>(nil)

    public convenience init() {
        self.init(provider: .gmail)
    }

    public convenience init(provider: IMAPProvider, codeWaitSignal: (any CodeWaitSignal)? = nil) {
        self.init(configuration: .production(provider), codeWaitSignal: codeWaitSignal)
    }

    init(configuration: IMAPFeedConfiguration, codeWaitSignal: (any CodeWaitSignal)? = nil) {
        GmailMailLogging.install()
        precondition(!configuration.backoff.isEmpty)
        precondition(configuration.catchupLimit > 0)
        precondition(configuration.maxBodyBytes > 0)
        precondition(configuration.livenessInterval > .zero)
        precondition(configuration.pollInterval > .zero)
        self.configuration = configuration
        self.codeWaitSignal = codeWaitSignal
    }

    public func run(
        login: IMAPAccountCredentials,
        onEvent: @escaping @Sendable (IMAPFeedEvent) async -> Void
    ) async throws {
        try await withTaskCancellationHandler {
            try await runLoop(login: login, onEvent: onEvent)
        } onCancel: {
            let server = active.withLock { $0 }
            Task { try? await server?.disconnect() }
        }
    }

    private func runLoop(
        login: IMAPAccountCredentials,
        onEvent: @escaping @Sendable (IMAPFeedEvent) async -> Void
    ) async throws {
        guard login.provider == configuration.provider.provider else {
            throw IMAPAccountError.credentialMismatch
        }
        let credentials = try IMAPAccountCredentials.validated(
            provider: login.provider, email: login.email, secret: login.secret)
        let attempt = Attempt()
        while true {
            try Task.checkCancellation()
            if attempt.failures > 0 {
                await Self.emitState(
                    .reconnecting, provider: configuration.provider.provider,
                    attempt: attempt, onEvent: onEvent)
                let index = min(attempt.failures - 1, configuration.backoff.count - 1)
                try await Task.sleep(for: configuration.backoff[index])
            } else {
                await Self.emitState(
                    .connecting, provider: configuration.provider.provider,
                    attempt: attempt, onEvent: onEvent)
            }
            do {
                try await session(credentials: credentials, attempt: attempt, onEvent: onEvent)
            } catch {
                let mapped = Self.map(error, provider: configuration.provider.provider)
                Self.logFailure(mapped, provider: configuration.provider.provider)
                if mapped is CancellationError || mapped is GmailIMAPError {
                    throw mapped
                }
                attempt.failures += 1
            }
        }
    }

    private func session(
        credentials: IMAPAccountCredentials,
        attempt: Attempt,
        onEvent: @escaping @Sendable (IMAPFeedEvent) async -> Void
    ) async throws {
        let host =
            configuration.host == configuration.provider.host
            ? try credentials.provider.imapHost(for: credentials.email) : configuration.host
        let server = IMAPServer(
            host: host,
            port: configuration.port,
            transportSecurity: configuration.transportSecurity,
            certificateVerificationPolicy: .fullVerification,
            minimumTLSVersion: .tlsv12,
            parserLimits: IMAPParserLimits(
                bodySizeLimit: UInt64(configuration.maxBodyBytes) + 1
            )
        )
        active.withLock { $0 = server }
        defer { active.withLock { if $0 === server { $0 = nil } } }

        do {
            if credentials.provider == .neteaseMail {
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                await server.setClientIdentification(
                    Identification(name: "Mail Code Filler", version: version))
            }
            try await server.connect()
            let usernames = try credentials.provider.loginUsernames(for: credentials.email)
            for (index, username) in usernames.enumerated() {
                do {
                    try await server.login(username: username, password: credentials.appPassword)
                    break
                } catch {
                    guard index + 1 < usernames.count, Self.isAuthenticationError(error) else {
                        throw error
                    }
                }
            }
            // SwiftMail stores a non-empty LOGIN capability list and does not send
            // CAPABILITY again. The watcher refreshes capabilities only if IDLE is absent.
            let watch = try await server.connection(named: "inbox-watch")
            var handled: Set<UInt32> = []
            var announcedFuture: Set<UInt32> = []
            var announcedIncomplete = false
            var announcedMissingValidity = false
            while true {
                try Task.checkCancellation()
                let watched = try await watch.examineMailbox(configuration.provider.inboxName)
                guard watched.isReadOnly else { throw GmailIMAPError.mailboxNotReadOnly }
                guard let stream = try await openIdle(watch) else {
                    try await followPolling(
                        server: server, watch: watch, accountID: credentials.accountID,
                        handled: &handled, announcedFuture: &announcedFuture,
                        announcedIncomplete: &announcedIncomplete,
                        announcedMissingValidity: &announcedMissingValidity,
                        attempt: attempt, onEvent: onEvent)
                    continue
                }
                let inbox = WatchInbox()
                let cadenceObserver = Task { [codeWaitSignal] in
                    guard let codeWaitSignal else { return }
                    for await _ in codeWaitSignal.updates() { inbox.activity() }
                }
                let consumer = Task {
                    for await event in stream {
                        if case .bye = event {
                            inbox.finish(.bye)
                            return
                        }
                        if Self.mailboxChanged(event) { inbox.activity() }
                    }
                    inbox.finish(.closed)
                }
                do {
                    let action = try await follow(
                        server: server, watch: watch, inbox: inbox,
                        accountID: credentials.accountID, handled: &handled,
                        announcedFuture: &announcedFuture,
                        announcedIncomplete: &announcedIncomplete,
                        announcedMissingValidity: &announcedMissingValidity,
                        attempt: attempt, onEvent: onEvent)
                    _ = await consumer.value
                    cadenceObserver.cancel()
                    _ = await cadenceObserver.value
                    if case .renew = action { continue }
                } catch {
                    consumer.cancel()
                    cadenceObserver.cancel()
                    try? await server.disconnect()
                    _ = await consumer.value
                    _ = await cadenceObserver.value
                    throw error
                }
            }
        } catch {
            try? await server.disconnect()
            throw error
        }
    }

    private func catchup(
        server: IMAPServer,
        selection: Mailbox.Selection,
        accountID: String,
        handled: inout Set<UInt32>,
        announcedFuture: inout Set<UInt32>,
        attempt: Attempt,
        synchronizedAt: ContinuousClock.Instant,
        yieldToNewMail: () -> Bool,
        onEvent: @escaping @Sendable (IMAPFeedEvent) async -> Void
    ) async throws -> Bool {
        handled.formUnion(attempt.skippedOversized)
        let count = selection.messageCount
        guard count > 0 else { return false }
        let upper = min(count, Int(UInt32.max))
        let start = max(1, upper - configuration.catchupLimit + 1)
        let infos = try await server.fetchMessageInfos(
            sequenceRange: SequenceNumber(UInt32(start))...SequenceNumber(UInt32(upper)),
            options: [.envelope, .internalDate, .bodyStructure]
        )
        let stamps = infos.compactMap { info -> GmailEnvelopeStamp? in
            guard let uid = info.uid?.value, uid > 0 else { return nil }
            return GmailEnvelopeStamp(
                uid: uid, internalDate: info.internalDate, sequence: info.sequenceNumber.value)
        }
        let decision = GmailCatchup.decide(
            stamps: stamps,
            messageCount: count,
            limit: configuration.catchupLimit,
            now: configuration.now(),
            retention: configuration.retention,
            futureSkew: configuration.futureSkew,
            handled: handled
        )
        if !decision.fetchUIDs.isEmpty {
            Self.logger.notice(
                "provider=\(self.configuration.provider.provider.rawValue, privacy: .public) event=fetch count=\(decision.fetchUIDs.count, privacy: .public)"
            )
        }
        for uid in decision.expiredUIDs {
            handled.insert(uid)
        }
        for uid in decision.undatedUIDs {
            handled.insert(uid)
            await onEvent(.notice(GmailNotice.unusableDate))
        }
        for uid in decision.futureUIDs where announcedFuture.insert(uid).inserted {
            await onEvent(.notice(GmailNotice.futureDate))
        }
        var byUID: [UInt32: MessageInfo] = [:]
        for info in infos {
            if let uid = info.uid?.value { byUID[uid] = info }
        }
        for uid in decision.fetchUIDs {
            try Task.checkCancellation()
            // A new push takes priority over the rest of this older snapshot.
            if yieldToNewMail() { break }
            guard let info = byUID[uid] else { continue }
            let loaded = try await load(server: server, info: info)
            switch loaded {
            case .message(let mail):
                if mail.hasUndecodablePart { await onEvent(.notice(GmailNotice.partialDecode)) }
                let received = decision.receivedAt[uid] ?? configuration.now()
                await onEvent(
                    .message(
                        ReceivedMail(
                            id: MailCodeCore.MessageID(
                                account: accountID, mailbox: configuration.provider.inboxName,
                                uidValidity: selection.uidValidity.value, uid: uid
                            ),
                            subject: mail.subject, bodies: mail.bodies, links: mail.links,
                            sender: mail.sender,
                            receivedAt: received,
                            fetchMilliseconds: Self.milliseconds(synchronizedAt.duration(to: .now))
                        )))
                handled.insert(uid)
            case .notice(let notice):
                if notice == GmailNotice.oversized { attempt.skippedOversized.insert(uid) }
                await onEvent(.notice(notice))
                handled.insert(uid)
            }
        }
        return decision.incomplete
    }

    private enum LoadResult {
        case message(GmailDecodedMail)
        case notice(String)
    }

    /// First plain part plus first HTML part, under one encoded-byte budget.
    /// Normalized bodies retain their boundaries for Core. This path does not decide whether a code is present.
    private func load(server: IMAPServer, info: MessageInfo) async throws -> LoadResult {
        let parts = GmailMessageText.readOrder(info.parts)
        guard !parts.isEmpty, let uid = info.uid?.value else { return .notice(GmailNotice.noText) }
        let budget = configuration.maxBodyBytes
        let knownSizes = parts.compactMap(\.size)
        if knownSizes.count == parts.count, knownSizes.reduce(0, +) > budget {
            return .notice(GmailNotice.oversized)
        }
        var fetched: [(GmailTextPart, Data)] = []
        var used = 0
        for part in parts {
            let room = budget - used
            if let size = part.size, size > room { return .notice(GmailNotice.oversized) }
            switch try await fetchBounded(server: server, section: part.section, uid: uid, room: room) {
            case .oversized:
                return .notice(GmailNotice.oversized)
            case .data(let bytes):
                used += bytes.count
                fetched.append(
                    (
                        GmailTextPart(
                            mime: part.contentType, transferEncoding: part.encoding),
                        bytes
                    ))
            }
        }
        switch GmailMessageText.decode(
            subject: info.subject, sender: info.from, parts: fetched, maxBytes: budget)
        {
        case .message(let mail):
            return .message(mail)
        case .notice(let notice):
            return .notice(notice)
        }
    }

    private enum BoundedBody {
        case data(Data)
        case oversized
    }

    /// `room + 1` is the probe. A full reply is over the shared budget and is not decoded.
    private func fetchBounded(
        server: IMAPServer, section: Section, uid: UInt32, room: Int
    ) async throws -> BoundedBody {
        if room <= 0 { return .oversized }
        let bytes: Data
        do {
            bytes = try await server.fetchPart(section: section, of: UID(uid), offset: 0, count: room + 1)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard GmailFetchLimit.isBound(error) || Self.partialWasOverBound(error) else { throw error }
            return .oversized
        }
        if bytes.count > room { return .oversized }
        return .data(bytes)
    }

    /// Uses the post-LOGIN snapshot. One CAPABILITY only if that snapshot has no IDLE.
    /// `nil` selects the bounded QQ-only poll path.
    private func openIdle(_ watch: IMAPNamedConnection) async throws -> AsyncStream<IMAPServerEvent>? {
        do {
            return try await watch.idle()
        } catch let error as IMAPError {
            guard case .commandNotSupported(let reason) = error,
                reason.range(of: "idle", options: [.caseInsensitive]) != nil
            else {
                throw error
            }
        }
        let refreshed = try await watch.fetchCapabilities()
        let advertised = refreshed.contains { capability in
            capability.name.compare("IDLE", options: [.caseInsensitive]) == .orderedSame
        }
        guard advertised else {
            guard configuration.provider.allowsPollingFallback else {
                throw GmailIMAPError.idleUnavailable
            }
            return nil
        }
        return try await watch.idle()
    }

    /// Watcher is already in IDLE. Primary EXAMINE/FETCH runs beside it, so an
    /// EXISTS during `onEvent` is not dropped on the fetch connection.
    private func follow(
        server: IMAPServer,
        watch: IMAPNamedConnection,
        inbox: WatchInbox,
        accountID: String,
        handled: inout Set<UInt32>,
        announcedFuture: inout Set<UInt32>,
        announcedIncomplete: inout Bool,
        announcedMissingValidity: inout Bool,
        attempt: Attempt,
        onEvent: @escaping @Sendable (IMAPFeedEvent) async -> Void
    ) async throws -> WatchAction {
        let deadline = ContinuousClock.now.advanced(by: configuration.idleRenewal)
        var nextLiveness = ContinuousClock.now.advanced(by: configuration.livenessInterval)
        var lastKnownExists = 0
        var needsCatchup = true
        while true {
            try Task.checkCancellation()
            if ContinuousClock.now >= deadline {
                inbox.expectStreamEnd()
                try await watch.done()
                return .renew
            }
            let mark = inbox.generation()
            if needsCatchup {
                await Self.emitState(
                    .synchronizing, provider: configuration.provider.provider,
                    attempt: attempt, onEvent: onEvent)
                let synchronizedAt = ContinuousClock.now
                let selection = try await server.examineMailbox(configuration.provider.inboxName)
                lastKnownExists = selection.messageCount
                guard selection.isReadOnly else { throw GmailIMAPError.mailboxNotReadOnly }
                if attempt.validity != selection.uidValidity.value {
                    if attempt.validity != nil { attempt.skippedOversized.removeAll() }
                    attempt.validity = selection.uidValidity.value
                    handled.removeAll()
                    announcedFuture.removeAll()
                    announcedIncomplete = false
                }
                if selection.uidValidity.value == 0 && !announcedMissingValidity {
                    announcedMissingValidity = true
                    await onEvent(.notice(GmailNotice.missingValidity))
                }
                let sawIncomplete = try await catchup(
                    server: server, selection: selection, accountID: accountID,
                    handled: &handled, announcedFuture: &announcedFuture,
                    attempt: attempt, synchronizedAt: synchronizedAt,
                    yieldToNewMail: { inbox.generation() != mark }, onEvent: onEvent)
                if sawIncomplete && !announcedIncomplete {
                    announcedIncomplete = true
                    await onEvent(.notice(GmailNotice.incomplete))
                }
                if !sawIncomplete { announcedIncomplete = false }
                if inbox.generation() != mark { continue }
                needsCatchup = false
            }
            attempt.failures = 0
            await Self.emitState(
                .listening, provider: configuration.provider.provider,
                attempt: attempt, onEvent: onEvent)
            let waiting = await codeWaitSignal?.currentWindow() != nil
            let interval = waiting ? configuration.codeWaitLivenessInterval : configuration.livenessInterval
            let nextCheck = min(nextLiveness, ContinuousClock.now.advanced(by: interval))
            let wake = try await IdleWait.wait(
                signaled: { try await inbox.next(since: mark) },
                renewal: ContinuousClock.now.duration(to: min(deadline, nextCheck)),
                disconnect: { try? await server.disconnect() }
            )
            switch wake {
            case .activity:
                needsCatchup = true
                continue
            case .timer:
                if ContinuousClock.now >= deadline {
                    inbox.expectStreamEnd()
                    try await watch.done()
                    return .renew
                }
                let events = try await server.noop()
                let existsCounts = events.compactMap { event -> Int? in
                    if case .exists(let count) = event { return count }
                    return nil
                }
                if let latest = existsCounts.max() {
                    let advanced = latest > lastKnownExists
                    lastKnownExists = max(lastKnownExists, latest)
                    if advanced {
                        Self.logger.notice(
                            "provider=\(self.configuration.provider.provider.rawValue, privacy: .public) event=mailbox_advanced exists_count=\(latest, privacy: .public)"
                        )
                        needsCatchup = true
                        continue
                    }
                }
                if events.contains(where: Self.mailboxChanged) || inbox.generation() != mark {
                    needsCatchup = true
                    continue
                }
                // A completed NOOP is the latest successful liveness check even
                // when it found no mail, so the account row can refresh.
                await Self.emitState(
                    .listening, provider: configuration.provider.provider,
                    attempt: attempt, onEvent: onEvent)
                nextLiveness = ContinuousClock.now.advanced(by: interval)
            case .bye, .closed:
                throw GmailTransportError()
            }
        }
    }

    /// QQ Mail's advertised IDLE normally keeps the watcher in push mode. If that
    /// capability disappears, poll only that account with selected-mailbox NOOPs.
    private func followPolling(
        server: IMAPServer,
        watch: IMAPNamedConnection,
        accountID: String,
        handled: inout Set<UInt32>,
        announcedFuture: inout Set<UInt32>,
        announcedIncomplete: inout Bool,
        announcedMissingValidity: inout Bool,
        attempt: Attempt,
        onEvent: @escaping @Sendable (IMAPFeedEvent) async -> Void
    ) async throws {
        var lastCheck = ContinuousClock.now
        while true {
            try Task.checkCancellation()
            await Self.emitState(
                .synchronizing, provider: configuration.provider.provider,
                attempt: attempt, onEvent: onEvent)
            let synchronizedAt = ContinuousClock.now
            let selection = try await server.examineMailbox(configuration.provider.inboxName)
            guard selection.isReadOnly else { throw GmailIMAPError.mailboxNotReadOnly }
            if attempt.validity != selection.uidValidity.value {
                if attempt.validity != nil { attempt.skippedOversized.removeAll() }
                attempt.validity = selection.uidValidity.value
                handled.removeAll()
                announcedFuture.removeAll()
                announcedIncomplete = false
            }
            if selection.uidValidity.value == 0 && !announcedMissingValidity {
                announcedMissingValidity = true
                await onEvent(.notice(GmailNotice.missingValidity))
            }
            let sawIncomplete = try await catchup(
                server: server, selection: selection, accountID: accountID,
                handled: &handled, announcedFuture: &announcedFuture,
                attempt: attempt, synchronizedAt: synchronizedAt,
                yieldToNewMail: { false }, onEvent: onEvent)
            if sawIncomplete && !announcedIncomplete {
                announcedIncomplete = true
                await onEvent(.notice(GmailNotice.incomplete))
            }
            if !sawIncomplete { announcedIncomplete = false }
            attempt.failures = 0
            lastCheck = ContinuousClock.now
            try await sleepForPoll(from: lastCheck)
            _ = try await watch.noop()
            await Self.emitState(
                .polling, provider: configuration.provider.provider,
                attempt: attempt, onEvent: onEvent)
        }
    }

    private func sleepForPoll(from start: ContinuousClock.Instant) async throws {
        while true {
            try Task.checkCancellation()
            let waiting = await codeWaitSignal?.currentWindow() != nil
            let interval = waiting ? configuration.codeWaitPollInterval : configuration.pollInterval
            let remaining = ContinuousClock.now.duration(to: start.advanced(by: interval))
            if remaining <= .zero { return }
            try await Task.sleep(for: min(remaining, .seconds(1)))
        }
    }

    private static func isAuthenticationError(_ error: Error) -> Bool {
        guard let error = error as? IMAPError else { return false }
        switch error {
        case .loginFailed, .authFailed: return true
        default: return false
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    private static func mailboxChanged(_ event: IMAPServerEvent) -> Bool {
        switch event {
        case .exists, .expunge, .vanished, .recent, .fetch, .fetchUID:
            return true
        default:
            return false
        }
    }

    private static func partialWasOverBound(_ error: Error) -> Bool {
        guard case .invalidResponse(let reason) = error as? PartialFetchError else { return false }
        return reason.range(of: "exceeded", options: .caseInsensitive) != nil
    }

    private static func map(_ error: Error, provider: IMAPProvider) -> Error {
        if error is CancellationError || error is GmailIMAPError || error is GmailTransportError {
            return error
        }
        guard let imap = error as? IMAPError else { return GmailTransportError() }
        if provider == .neteaseMail, let reason = Self.serverReason(imap) {
            let text = reason.lowercased()
            if ["frequency limit", "rate limit", "too many connections", "流量限制", "连接过于频繁"]
                .contains(where: text.contains)
            {
                return GmailIMAPError.rateLimited
            }
        }
        switch imap {
        case .loginFailed, .authFailed, .unsupportedAuthMechanism:
            return GmailIMAPError.authenticationRejected
        case .commandNotSupported(let reason) where reason.range(of: "idle", options: .caseInsensitive) != nil:
            return GmailIMAPError.idleUnavailable
        default:
            return GmailTransportError(category: transportErrorCategory(imap))
        }
    }

    private static func serverReason(_ error: IMAPError) -> String? {
        switch error {
        case .loginFailed(let reason), .authFailed(let reason), .commandFailed(let reason),
            .selectFailed(let reason), .connectionFailed(let reason):
            return reason
        default: return nil
        }
    }

    private static func emitState(
        _ state: IMAPFeedState,
        provider: IMAPProvider,
        attempt: Attempt,
        onEvent: @escaping @Sendable (IMAPFeedEvent) async -> Void
    ) async {
        if attempt.lastReportedState != state {
            attempt.lastReportedState = state
            logger.notice(
                "provider=\(provider.rawValue, privacy: .public) state=\(state.logName, privacy: .public) reconnect_attempt=\(attempt.failures, privacy: .public)"
            )
        }
        await onEvent(.state(state))
    }

    private static func logFailure(_ error: Error, provider: IMAPProvider) {
        let category: String
        if error is CancellationError {
            category = "cancelled"
        } else if let imap = error as? IMAPError {
            if case .timeout = imap { category = "timeout" } else { category = "imap" }
        } else if let terminal = error as? GmailIMAPError {
            switch terminal {
            case .authenticationRejected: category = "authentication"
            case .idleUnavailable: category = "idle_unavailable"
            case .mailboxNotReadOnly: category = "mailbox_mode"
            case .rateLimited: category = "rate_limited"
            }
        } else if let transport = error as? GmailTransportError {
            category = transport.category
        } else {
            category = "internal"
        }
        logger.notice(
            "provider=\(provider.rawValue, privacy: .public) event=connection_error category=\(category, privacy: .public)"
        )
    }
}

extension IMAPFeedState {
    fileprivate var logName: String {
        switch self {
        case .connecting: "connecting"
        case .synchronizing: "synchronizing"
        case .listening: "listening"
        case .polling: "polling"
        case .reconnecting: "reconnecting"
        }
    }
}

private struct GmailTransportError: Error {
    let category: String

    init(category: String = "transport") {
        self.category = category
    }
}

private func transportErrorCategory(_ error: Error) -> String {
    guard let imap = error as? IMAPError else { return "transport" }
    switch imap {
    case .timeout: return "timeout"
    case .connectionFailed: return "connection"
    default: return "imap"
    }
}

public typealias GmailIMAPFeed = IMAPAccountFeed

private final class Attempt: @unchecked Sendable {
    var failures = 0
    var validity: UInt32?
    var lastReportedState: IMAPFeedState?
    /// UIDs skipped because a fetch exceeded a known body limit. Survives reconnect
    /// for the same UIDVALIDITY so a hostile literal is not fetched forever.
    var skippedOversized: Set<UInt32> = []
}

enum GmailFetchLimit {
    static func isBound(_ error: Error) -> Bool {
        if error is ExceededResponseBodySizeError { return true }
        if boundTypeName(String(reflecting: type(of: error))) { return true }
        for child in Mirror(reflecting: error).children {
            guard child.label == "parserError", let nested = child.value as? Error else { continue }
            return isBound(nested)
        }
        return false
    }

    private static func boundTypeName(_ name: String) -> Bool {
        [
            "ExceededMaximumBodySizeError",
            "ExceededMaximumMessageAttributesError",
            "ExceededLiteralSizeLimitError",
            "ExceededResponseBodySizeError",
        ].contains { name.contains($0) }
    }
}

private enum WatchAction: Sendable {
    case renew
}

private enum IdleWake: Sendable {
    case activity
    case timer
    case bye
    case closed
}

/// Events the watcher IDLE sees while the primary connection is fetching.
private final class WatchInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var generationValue = 0
    private var terminal: IdleWake?
    private var expectEnd = false
    private var waiters: [OnceResume] = []

    func generation() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generationValue
    }

    func activity() {
        let pending = takeWaiters { generationValue += 1 }
        for waiter in pending { waiter.resume(returning: .activity) }
    }

    func expectStreamEnd() {
        lock.lock()
        expectEnd = true
        lock.unlock()
    }

    func finish(_ wake: IdleWake) {
        let pending: [OnceResume] = {
            lock.lock()
            defer { lock.unlock() }
            if expectEnd, wake == .closed {
                expectEnd = false
                return []
            }
            terminal = wake
            let pending = waiters
            waiters = []
            return pending
        }()
        for waiter in pending { waiter.resume(returning: wake) }
    }

    func next(since mark: Int) async throws -> IdleWake {
        let flag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let once = OnceResume(continuation)
                flag.lock.lock()
                let cancelled = flag.cancelled
                flag.once = once
                flag.lock.unlock()
                if cancelled {
                    once.resume(throwing: CancellationError())
                    return
                }
                lock.lock()
                if let terminal {
                    lock.unlock()
                    once.resume(returning: terminal)
                    return
                }
                if generationValue != mark {
                    lock.unlock()
                    once.resume(returning: .activity)
                    return
                }
                waiters.append(once)
                lock.unlock()
            }
        } onCancel: {
            flag.lock.lock()
            flag.cancelled = true
            let once = flag.once
            flag.lock.unlock()
            once?.resume(throwing: CancellationError())
            lock.lock()
            waiters.removeAll { $0 === once }
            lock.unlock()
        }
    }

    private func takeWaiters(_ mutate: () -> Void) -> [OnceResume] {
        lock.lock()
        mutate()
        let pending = waiters
        waiters = []
        lock.unlock()
        return pending
    }
}

private final class CancelFlag: @unchecked Sendable {
    let lock = NSLock()
    var cancelled = false
    var once: OnceResume?
}

private final class OnceResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<IdleWake, Error>?

    init(_ continuation: CheckedContinuation<IdleWake, Error>) {
        self.continuation = continuation
    }

    func resume(returning wake: IdleWake) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: wake)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}

private enum IdleRace: Sendable {
    case wake(IdleWake)
    case stopped
}

private enum IdleWait {
    /// Races the IDLE stream against the next timer and joins both children before returning.
    static func wait(
        signaled: @escaping @Sendable () async throws -> IdleWake,
        renewal: Duration,
        disconnect: @escaping @Sendable () async -> Void
    ) async throws -> IdleWake {
        try await withTaskCancellationHandler {
            try await race(
                signaled: signaled, renewal: renewal, disconnect: disconnect)
        } onCancel: {
            Task { await disconnect() }
        }
    }

    private static func race(
        signaled: @escaping @Sendable () async throws -> IdleWake,
        renewal: Duration,
        disconnect: @escaping @Sendable () async -> Void
    ) async throws -> IdleWake {
        try await withThrowingTaskGroup(of: IdleRace.self) { group in
            group.addTask {
                do {
                    try await Task.sleep(for: renewal)
                    return .wake(.timer)
                } catch {
                    return .stopped
                }
            }
            group.addTask {
                do {
                    return .wake(try await signaled())
                } catch is CancellationError {
                    return .stopped
                }
            }

            guard let first = try await group.next() else {
                group.cancelAll()
                throw CancellationError()
            }
            group.cancelAll()
            let wake: IdleWake
            switch first {
            case .stopped:
                await disconnect()
                try await drain(&group)
                throw CancellationError()
            case .wake(.timer):
                try await drain(&group)
                try Task.checkCancellation()
                return .timer
            case .wake(let other):
                wake = other
            }
            try await drain(&group)
            try Task.checkCancellation()
            return wake
        }
    }

    private static func drain(_ group: inout ThrowingTaskGroup<IdleRace, Error>) async throws {
        while try await group.next() != nil {}
    }
}
