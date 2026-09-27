import Foundation
import Observation

public enum IMAPAccountSessionPhase: Equatable, Sendable {
    case notConfigured
    case paused
    case active(IMAPFeedState)
    case stopping
    case failed
}

@MainActor @Observable
public final class IMAPAccountSession {
    public let account: IMAPAccount
    public var email: String { account.email }
    public private(set) var phase: IMAPAccountSessionPhase = .notConfigured
    public private(set) var message: String
    public private(set) var lastSynchronizedAt: Date?
    public private(set) var notice: String?
    public private(set) var recognitionNotice: String?
    public private(set) var lastProcessingSummary: String?
    public var onCandidatesChanged: (@MainActor () async -> Void)?
    public var recentMissedMail: RecentMissedMailRing?

    @ObservationIgnored private let vault: CandidateVault
    @ObservationIgnored private let feed: any IMAPFeed
    @ObservationIgnored private let credentials: any IMAPAccountCredentialStore
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let linkCardLevel: @MainActor () -> LinkCardLevel
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var semanticResolver: (any SemanticCodeResolver)?
    @ObservationIgnored var semanticJobs: [MessageID: Task<Void, Never>] = [:]
    private var semanticSeen: [MessageID: Date] = [:]
    private var semanticEpoch = UUID()

    public init(
        account: IMAPAccount, vault: CandidateVault, feed: any IMAPFeed,
        credentials: any IMAPAccountCredentialStore = KeychainIMAPCredentialStore(),
        preferences: UserDefaults = .standard,
        linkCardLevel: @escaping @MainActor () -> LinkCardLevel = { .signInAndVerification }
    ) {
        self.account = account
        self.vault = vault
        self.feed = feed
        self.credentials = credentials
        self.preferences = preferences
        self.linkCardLevel = linkCardLevel
        message = "连接\(account.descriptor.displayName)后，自动接收最近 10 分钟的验证码。"
    }

    public var isActive: Bool {
        if case .active = phase { return true }
        return false
    }

    public func restore() {
        guard task == nil, phase == .notConfigured else { return }
        do {
            guard let login = try credentials.load(accountID: account.id) else { return }
            try validateIdentity(login)
            if isPersistedPaused {
                phase = .paused
                message = "监听已暂停，验证码不会在后台收取。"
            } else {
                start(login)
            }
        } catch { fail(error) }
    }

    public func connect(secret: String) throws {
        let login = try IMAPAccountCredentials.validated(
            provider: account.provider, email: account.email, secret: secret)
        try credentials.save(login, accountID: account.id)
        setPersistedPaused(false)
        start(login)
    }

    /// Compatibility entry point for Gmail callers while the UI migrates to provider-neutral forms.
    public func connect(email: String, appPassword: String) throws {
        guard account.provider == .gmail,
            email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == account.email
        else { throw IMAPAccountError.credentialMismatch }
        try connect(secret: appPassword)
    }

    public func resume() {
        guard !isActive, phase != .stopping else { return }
        do {
            guard let login = try credentials.load(accountID: account.id) else {
                phase = .notConfigured
                message = "没有保存的\(account.descriptor.displayName)凭据，请更新凭据。"
                return
            }
            try validateIdentity(login)
            setPersistedPaused(false)
            start(login)
        } catch { fail(error) }
    }

    public func pause() async {
        setPersistedPaused(true)
        await stopListening(finalPhase: .paused).value
    }

    public func removeAccount() async throws {
        try credentials.remove(accountID: account.id)
        setPersistedPaused(true)
        await stopListening(finalPhase: .notConfigured).value
        await recentMissedMail?.remove(accountID: account.id)
    }

    public func reconnectAfterWake() {
        reconnectForConnectivityChange()
    }

    public func reconnectAfterNetworkChange() {
        reconnectForConnectivityChange()
    }

    private func reconnectForConnectivityChange() {
        guard isActive else { return }
        do {
            guard let login = try credentials.load(accountID: account.id) else {
                throw IMAPAccountError.damagedCredential
            }
            try validateIdentity(login)
            // A sleeping socket can appear connected long after the network has changed.
            start(login, preserveLastSynchronizedAt: true)
        } catch {
            task?.cancel()
            generation = UUID()
            fail(error)
        }
    }

    public func shutdown() {
        task?.cancel()
        cancelSemanticJobs()
        if let recentMissedMail { Task { await recentMissedMail.clear() } }
    }

    public func setSemanticResolver(_ resolver: (any SemanticCodeResolver)?) {
        cancelSemanticJobs()
        semanticResolver = resolver
        recognitionNotice = nil
    }

    private var isPersistedPaused: Bool {
        preferences.bool(forKey: IMAPAccountRegistry.pausedKey(accountID: account.id))
    }

    private func setPersistedPaused(_ value: Bool) {
        preferences.set(value, forKey: IMAPAccountRegistry.pausedKey(accountID: account.id))
    }

    private func validateIdentity(_ login: IMAPAccountCredentials) throws {
        guard login.accountID == account.id, login.provider == account.provider,
            login.email == account.email
        else { throw IMAPAccountError.credentialMismatch }
    }

    private func cancelSemanticJobs() {
        semanticEpoch = UUID()
        for job in semanticJobs.values { job.cancel() }
        semanticJobs.removeAll()
    }

    private func start(_ login: IMAPAccountCredentials, preserveLastSynchronizedAt: Bool = false) {
        cancelSemanticJobs()
        semanticSeen.removeAll()
        recognitionNotice = nil
        lastProcessingSummary = nil
        let previous = task
        previous?.cancel()
        let token = UUID()
        generation = token
        phase = .active(.connecting)
        message = "正在通过加密连接登录\(account.descriptor.displayName)…"
        if !preserveLastSynchronizedAt { lastSynchronizedAt = nil }
        notice = nil
        let feed = feed
        task = Task { [weak self] in
            // Join the previous feed so late body callbacks cannot repopulate removed candidates.
            await previous?.value
            guard !Task.isCancelled, self?.generation == token else { return }
            do {
                try await feed.run(login: login) { [weak self] event in
                    await self?.receive(event, generation: token)
                }
                guard !Task.isCancelled, self?.generation == token else { return }
                self?.phase = .failed
                self?.message = "\(self?.account.descriptor.displayName ?? "邮箱")监听已结束，请重新连接。"
            } catch {
                guard !Task.isCancelled, self?.generation == token else { return }
                self?.fail(error)
            }
        }
    }

    private func stopListening(finalPhase: IMAPAccountSessionPhase) -> Task<Void, Never> {
        cancelSemanticJobs()
        semanticSeen.removeAll()
        recognitionNotice = nil
        lastProcessingSummary = nil
        let previous = task
        previous?.cancel()
        let token = UUID()
        generation = token
        phase = .stopping
        message = "正在停止\(account.descriptor.displayName)监听…"
        let vault = vault
        let accountID = account.id
        let providerName = account.descriptor.displayName
        let stopping = Task { [weak self] in
            await previous?.value
            await vault.remove(account: accountID)
            guard self?.generation == token else { return }
            self?.phase = finalPhase
            self?.message =
                finalPhase == .notConfigured
                ? "已移除\(providerName)凭据与本地候选。"
                : "\(providerName)监听已暂停，本地候选已清除。"
            self?.lastSynchronizedAt = nil
            self?.notice = nil
            await self?.onCandidatesChanged?()
        }
        task = stopping
        return stopping
    }

    private func receive(_ event: IMAPFeedEvent, generation token: UUID) async {
        guard generation == token, !Task.isCancelled else { return }
        switch event {
        case .state(let state):
            phase = .active(state)
            switch state {
            case .connecting:
                message = "正在通过加密连接登录\(account.descriptor.displayName)…"
            case .synchronizing:
                message = "正在检查最近邮件，邮件保持原有已读状态。"
            case .listening:
                message = "正在监听\(account.descriptor.displayName)，新验证码会自动出现在这里。"
                lastSynchronizedAt = Date()
            case .polling:
                message = "轮询（约 10 秒）\(account.descriptor.displayName)，新验证码会自动出现在这里。"
                lastSynchronizedAt = Date()
            case .reconnecting:
                message = "连接可能中断，正在重连；恢复后会补查最近邮件。"
            }
        case .notice(let notice): self.notice = notice
        case .message(let mail):
            let started = ContinuousClock.now
            let codes = CodeDetector().codes(subject: mail.subject, bodies: mail.bodies)
            let detectedLink = SignInLinkDetector().detect(
                subject: mail.subject, bodies: mail.bodies, links: mail.links)
            let loginLink = detectedLink.flatMap { linkCardLevel().allows($0.purpose) ? $0 : nil }
            if !codes.isEmpty || loginLink != nil {
                await recentMissedMail?.remove(mail.id)
                recordTiming(mail, since: started, source: "本地")
                await publish(mail, codes: codes, loginLink: loginLink, generation: token)
            } else if detectedLink == nil {
                await recentMissedMail?.record(mail)
            }
            if codes.isEmpty {
                scheduleSemantic(mail, generation: token)
            }
        }
    }

    private func scheduleSemantic(_ mail: ReceivedMail, generation token: UUID) {
        let now = Date()
        semanticSeen = semanticSeen.filter { $0.value > now }
        guard let resolver = semanticResolver, semanticSeen[mail.id] == nil,
            mail.receivedAt.addingTimeInterval(CandidateVault.retention) > now,
            !JevMailInput(mail).candidates.isEmpty
        else { return }
        semanticSeen[mail.id] = mail.receivedAt.addingTimeInterval(CandidateVault.retention)
        let epoch = semanticEpoch
        // Do not hold the IMAP callback while a cloud request is pending.
        semanticJobs[mail.id] = Task { [weak self] in
            let started = ContinuousClock.now
            defer {
                if self?.semanticEpoch == epoch { self?.semanticJobs[mail.id] = nil }
            }
            do {
                let code = try await resolver.code(in: mail)
                guard !Task.isCancelled, let self, self.generation == token,
                    self.semanticEpoch == epoch
                else { return }
                self.recordTiming(mail, since: started, source: "Jev")
                if let code {
                    await self.recentMissedMail?.remove(mail.id)
                    await self.publish(mail, codes: [code], loginLink: nil, generation: token)
                }
            } catch {
                guard !Task.isCancelled, self?.generation == token, self?.semanticEpoch == epoch else {
                    return
                }
                self?.recognitionNotice =
                    (error as? JevError)?.errorDescription ?? JevError.unavailable.errorDescription
            }
        }
    }

    private func publish(
        _ mail: ReceivedMail, codes: [String], loginLink: SignInLink? = nil,
        generation token: UUID
    ) async {
        guard generation == token, !Task.isCancelled else { return }
        await vault.insert(
            message: mail.id, codes: codes, loginLink: loginLink,
            source: mail.sender, subject: mail.subject,
            receivedAt: mail.receivedAt, now: Date(), isFromJunk: mail.isFromJunk)
        guard generation == token, !Task.isCancelled else { return }
        await onCandidatesChanged?()
    }

    private func recordTiming(_ mail: ReceivedMail, since start: ContinuousClock.Instant, source: String) {
        let parts = start.duration(to: .now).components
        let milliseconds = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
        let fetched = mail.fetchMilliseconds.map { "本轮同步至正文 \(Int($0)) ms · " } ?? ""
        lastProcessingSummary = fetched + "\(source)识别 \(String(format: "%.1f", milliseconds)) ms"
    }

    private func fail(_ error: Error) {
        cancelSemanticJobs()
        phase = .failed
        message =
            (error as? LocalizedError)?.errorDescription
            ?? "\(account.descriptor.displayName)连接失败，请检查网络和登录凭据后重试。"
    }
}

public typealias GmailSession = IMAPAccountSession
public typealias GmailSessionPhase = IMAPAccountSessionPhase
