import AppKit
import ApplicationServices
import AuthenticationServices
import MailCodeAutoFill
import MailCodeCore
import MailCodeGmail
import Observation

enum ArrivalActionResult: Equatable {
    case filled
    case copied
    case opened
    case copiedAfterFailure(String)
    case failed(String)

    var feedback: String {
        switch self {
        case .filled: "已填入输入框"
        case .copied: "已复制，按 ⌘V 粘贴"
        case .opened: "已在默认浏览器打开链接"
        case .copiedAfterFailure(let message), .failed(let message): message
        }
    }
}

struct ArrivalNotice {
    let candidates: [Candidate]
    let automaticCopyCandidateID: Candidate.ID?
    let automaticallyCopied: Bool
    let automaticCopyFeedback: String?
}

@MainActor @Observable
final class AppModel {
    let vault = CandidateVault()
    let codeWaitController = CodeWaitModeController()
    let recentMissedMail = RecentMissedMailRing()
    let loginManager = LaunchAtLoginController(backend: SMAppLaunchAtLogin())
    @ObservationIgnored lazy var activePageProvider = BrowserActivePageProvider { [weak self] in
        self?.settings.allowsBrowserAutomation ?? false
    }
    private(set) var accounts: [IMAPAccountSession] = []
    private(set) var accountRecords: [IMAPAccount] = []
    private(set) var accountSetupProblem: String?
    private(set) var autoFill: AutoFillPublisher?
    private(set) var autoFillProblem: String?
    private(set) var candidates: [Candidate] = []
    private(set) var selection = CandidateSelection()
    let supportsAutoFill = Bundle.main.object(forInfoDictionaryKey: "MailCodeAutoFillAccessGroup") != nil
    let isOfflinePreview = ProcessInfo.processInfo.arguments.contains("--offline-preview")
    var status = "收到新码会自动提示；卡片点击行为可在识别与提示设置中选择。"
    let settings: DeliverySettings
    private(set) var jevProblem: String?
    private(set) var jevStatus = "仅本地识别，未启用 Jev。"
    var onCandidateConsumed: ((Candidate.ID) -> Void)?
    var onDoNotDisturbStarted: (() -> Void)?
    var onScreenshotSettingChanged: ((Bool) -> Void)?
    private(set) var lastCopiedID: Candidate.ID?
    var onArrival: ((ArrivalNotice) -> Void)?
    var onCandidateListChanged: (() -> Void)?
    var onShortcutBindingsChanged: ((ShortcutBinding, ShortcutBinding) -> Bool)?
    var onCodeWaitTriggerSettingsChanged: (() -> Void)?
    private(set) var isDoNotDisturbActive = false
    @ObservationIgnored private let clipboard = CandidateClipboard()
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let accountRegistry: IMAPAccountRegistry
    @ObservationIgnored private let credentials: KeychainIMAPCredentialStore
    @ObservationIgnored private let legacyGmailCredentials: KeychainGmailCredentialStore
    @ObservationIgnored private let microsoftOAuthCoordinator = MicrosoftOAuthCoordinator()
    @ObservationIgnored private let microsoftTokenManager: MicrosoftOAuthTokenManager?
    private var arrivals = CandidateArrivalTracker(launchGrace: 180)
    var shortcutStatus = "快捷键尚未注册"
    var targetName: String?
    private(set) var isBusy = false
    private var uid: UInt32 = 0
    private var refreshVersion = 0
    private var isStopping = false
    @ObservationIgnored private var expirationTask: Task<Void, Never>?
    @ObservationIgnored private var doNotDisturbTimer: Task<Void, Never>?
    @ObservationIgnored lazy var fillCoordinator = FillCoordinator(vault: vault)

    init() {
        let preferences =
            isOfflinePreview
            ? UserDefaults(suiteName: "dev.zhijie.MailCodeFiller.offline-preview")! : .standard
        self.preferences = preferences
        accountRegistry = IMAPAccountRegistry(preferences: preferences)
        credentials = KeychainIMAPCredentialStore()
        legacyGmailCredentials = KeychainGmailCredentialStore()
        if let clientID = MicrosoftOAuth.clientID() {
            microsoftTokenManager = MicrosoftOAuthTokenManager(
                client: MicrosoftOAuthTokenClient(clientID: clientID),
                store: KeychainMicrosoftRefreshTokenStore())
        } else {
            microsoftTokenManager = nil
        }
        settings = DeliverySettings(preferences: preferences)
        isDoNotDisturbActive = settings.doNotDisturbPeriod?.isActive(at: Date()) ?? false
        if let period = settings.doNotDisturbPeriod { arrivals.recordQuietPeriod(period) }
    }

    var selectedID: Candidate.ID? { selection.id }
    var accessibilityPermissionGranted: Bool { AXIsProcessTrusted() }

    func openAccessibilityPrivacySettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    func setScreenshotPermission(_ allowed: Bool) {
        settings.allowsScreenshots = allowed
        onScreenshotSettingChanged?(allowed)
    }

    func setClipboardAutoClearEnabled(_ enabled: Bool) {
        settings.clipboardAutoClearEnabled = enabled
        if !enabled { clipboard.autoClear.cancel() }
    }

    func updateShortcutBindings(fill: ShortcutBinding, chooser: ShortcutBinding) -> Bool {
        guard fill.isValid, chooser.isValid, !fill.conflicts(with: chooser) else {
            shortcutStatus = "快捷键无效或两个动作使用了同一组合。"
            return false
        }
        guard onShortcutBindingsChanged?(fill, chooser) == true else {
            shortcutStatus = "快捷键被其他 App 占用；保留原组合，请更换后重试。"
            return false
        }
        settings.fillShortcut = fill
        settings.chooserShortcut = chooser
        shortcutStatus = "\(fill.displayName) · 快速填入；\(chooser.displayName) · 选择验证码"
        return true
    }

    func start() {
        if supportsAutoFill && !isOfflinePreview { configureAutoFill() }
        if !isOfflinePreview {
            restoreJev()
            restoreAccounts()
        }
        Task { await reconcileDoNotDisturb() }
    }

    func refreshAutoFill() async {
        if supportsAutoFill && !isOfflinePreview && autoFill == nil { configureAutoFill() }
        await refresh()
    }

    func openAutoFillSettings() async {
        do { try await ASSettingsHelper.openCredentialProviderAppSettings() } catch {
            autoFillProblem = "无法打开系统 AutoFill 设置，请手动打开系统设置 → 通用 → 自动填充与密码。"
        }
    }

    func associate(_ id: Candidate.ID, with domain: String) throws {
        guard let autoFill else { throw AutoFillError.missingConfiguration }
        guard let candidate = candidates.first(where: { $0.id == id }), candidate.expiresAt > Date(),
            accountRecords.contains(where: { $0.id == candidate.id.message.account }), candidate.isCode
        else { throw FillError.expired }
        try autoFill.addRule(for: candidate, domain: domain)
    }

    func removeAccount(_ accountID: String) async throws {
        guard let session = accounts.first(where: { $0.account.id == accountID }) else { return }
        // Preserve the existing session and credentials if explicit rule cleanup fails.
        try autoFill?.removeRules(account: accountID)
        if session.account.provider == .outlook {
            if let microsoftTokenManager {
                try await microsoftTokenManager.remove(accountID: accountID)
            } else {
                // Accounts remain removable even if a later build has no Client ID.
                try KeychainMicrosoftRefreshTokenStore().remove(accountID: accountID)
            }
        }
        try await session.removeAccount()
        accounts.removeAll { $0.account.id == accountID }
        accountRecords.removeAll { $0.id == accountID }
        accountRegistry.save(accountRecords)
        preferences.removeObject(forKey: IMAPAccountRegistry.pausedKey(accountID: accountID))
        await refresh()
    }

    private func configureAutoFill() {
        do {
            let group =
                Bundle.main.object(forInfoDictionaryKey: "MailCodeAutoFillAccessGroup") as? String ?? ""
            let publisher = try AutoFillPublisher(
                store: KeychainAutoFillStore(accessGroup: group), index: SystemAutoFillIndex())
            try publisher.restore()
            autoFill = publisher
            autoFillProblem = nil
        } catch { autoFillProblem = error.localizedDescription }
    }

    func connectAccount(provider: IMAPProvider, email: String, secret: String) async throws {
        guard !isOfflinePreview else {
            throw NSError(
                domain: "MailCodeFiller", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "离线预览不访问邮箱或钥匙串，请正常打开 App 后连接账户。"])
        }
        let validated = try IMAPAccountCredentials.validated(provider: provider, email: email, secret: secret)
        let account = IMAPAccount(provider: provider, email: validated.email)
        let session: IMAPAccountSession
        let isNewAccount = !accounts.contains(where: { $0.account.id == account.id })
        if let existing = accounts.first(where: { $0.account.id == account.id }) {
            session = existing
        } else {
            session = makeSession(for: account)
        }
        try session.connect(secret: validated.secret)
        if isNewAccount { accounts.append(session) }
        if !accountRecords.contains(where: { $0.id == account.id }) {
            accountRecords.append(account)
            accountRegistry.save(accountRecords)
        }
        accountRegistry.migrateLegacyGmailPause(for: account)
        await vault.remove(account: "demo@example.test")
        await refresh()
        status = "已保存到本机钥匙串。连接状态按账户分别显示；收到新验证码时会自动提示。"
    }

    var isOutlookConfigured: Bool { microsoftTokenManager != nil }
    var microsoftSignInNotice: String?

    enum MicrosoftSignInStatus: Equatable {
        case idle
        case waiting
        case succeeded
        case failed(String)
    }

    /// The sign-in runs on the model, not the form: the menu bar panel closes as soon as the
    /// browser takes focus, and cancelling on disappear killed the loopback listener before the
    /// browser redirected back ("The site refused the connection").
    private(set) var microsoftSignInStatus: MicrosoftSignInStatus = .idle
    @ObservationIgnored private var microsoftSignInTask: Task<Void, Never>?

    func startMicrosoftSignIn(email: String) {
        microsoftSignInTask?.cancel()
        microsoftSignInStatus = .waiting
        microsoftSignInTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await connectMicrosoftAccount(email: email)
                microsoftSignInStatus = .succeeded
            } catch {
                if Task.isCancelled || error is CancellationError {
                    microsoftSignInStatus = .idle
                } else {
                    microsoftSignInStatus = .failed(
                        (error as? LocalizedError)?.errorDescription ?? "登录失败，请重试。")
                }
            }
            microsoftSignInTask = nil
        }
    }

    func cancelMicrosoftSignIn() {
        microsoftSignInTask?.cancel()
        microsoftSignInTask = nil
        microsoftOAuthCoordinator.cancel()
        microsoftSignInStatus = .idle
    }

    func acknowledgeMicrosoftSignIn() {
        if microsoftSignInStatus != .waiting { microsoftSignInStatus = .idle }
    }

    func connectMicrosoftAccount(email: String) async throws {
        guard !isOfflinePreview, let clientID = MicrosoftOAuth.clientID(),
            let microsoftTokenManager
        else { throw MicrosoftOAuthError.missingClientID }
        let validated = try IMAPAccountCredentials.validated(provider: .outlook, email: email, secret: "")
        let client = MicrosoftOAuthTokenClient(clientID: clientID, loginHint: validated.email)
        microsoftSignInNotice = nil
        let authorization = try await microsoftOAuthCoordinator.authorize(client: client) {
            self.microsoftSignInNotice = "本机回调无法启动，将改用系统登录窗口（可能在 Safari 中打开）。"
        }
        try Task.checkCancellation()
        let differentSignIn = try await microsoftTokenManager.authorize(
            code: authorization.code, verifier: authorization.verifier,
            redirectURI: authorization.redirectURI,
            accountID: validated.accountID, expectedEmail: validated.email)
        if let differentSignIn {
            microsoftSignInNotice =
                "浏览器登录的账号显示为 \(differentSignIn)。如果它是 \(validated.email) 的别名可以忽略；若收信被拒，请在登录页切换到 \(validated.email)。"
        }
        try Task.checkCancellation()
        try await connectAccount(provider: .outlook, email: validated.email, secret: "")
    }

    var hasConfiguredAccounts: Bool { !accountRecords.isEmpty }
    var receivingMailboxesVisible: Bool { accountRecords.count > 1 }
    var recognitionNotice: String? { accounts.compactMap(\.recognitionNotice).first }
    var lastProcessingSummary: String? { accounts.compactMap(\.lastProcessingSummary).first }
    var emptyCandidateDescription: String {
        guard !accountRecords.isEmpty else {
            return "连接 Gmail、QQ、iCloud、网易或 Outlook 邮箱，或先离线试用。\n新码自动提示，复制后手动粘贴。"
        }
        if accounts.contains(where: { $0.phase == .failed }) {
            return "至少一个邮箱连接需要处理。\n请查看上方各账户状态。"
        }
        if accounts.contains(where: {
            switch $0.phase {
            case .stopping, .active(.connecting), .active(.synchronizing), .active(.reconnecting): true
            default: false
            }
        }) {
            return "部分邮箱仍在连接或同步。\n同步完成前还不能判断是否有新验证码。"
        }
        if accounts.allSatisfy({ $0.phase == .paused || $0.phase == .notConfigured }) {
            return "邮箱监听已暂停或尚未配置凭据。\n恢复连接后会补查最近邮件。"
        }
        let folders = settings.checksJunkFolder ? "INBOX 和垃圾邮件文件夹" : "INBOX"
        return "最近 10 分钟暂未识别到验证码。\n各账户检查\(folders)；新邮件到达后会自动处理。"
    }

    func receivingMailbox(for candidate: Candidate) -> String? {
        guard receivingMailboxesVisible else { return nil }
        return accountRecords.first(where: { $0.id == candidate.id.message.account })?.email
    }

    func session(for candidate: Candidate) -> IMAPAccountSession? {
        accounts.first { $0.account.id == candidate.id.message.account }
    }

    private func makeSession(for account: IMAPAccount) -> IMAPAccountSession {
        let session = IMAPAccountSession(
            account: account, vault: vault,
            feed: IMAPAccountFeed(
                provider: account.provider, codeWaitSignal: codeWaitController,
                microsoftTokens: microsoftTokenManager,
                checksJunkFolder: { [weak self] in self?.settings.checksJunkFolder ?? false }),
            credentials: credentials, preferences: preferences,
            linkCardLevel: { [weak self] in self?.settings.linkCardLevel ?? .signInAndVerification })
        session.recentMissedMail = recentMissedMail
        session.onCandidatesChanged = { [weak self] in await self?.refresh() }
        if settings.jevEnabled, let key = try? JevCredentialStore().load() {
            session.setSemanticResolver(try? JevCodeResolver(apiKey: key))
        }
        return session
    }

    private func restoreAccounts() {
        var records = accountRegistry.load()
        do {
            if let legacy = try legacyGmailCredentials.load() {
                let account = IMAPAccount(provider: .gmail, email: legacy.email)
                _ = try GmailCredentialMigrator.migrate(
                    account: account, legacy: legacyGmailCredentials, perAccount: credentials)
                if !records.contains(where: { $0.id == account.id }) { records.append(account) }
                accountRegistry.migrateLegacyGmailPause(for: account)
            }
        } catch {
            accountSetupProblem = error.localizedDescription
        }
        for account in records { accountRegistry.migrateLegacyGmailPause(for: account) }
        accountRecords = records
        accountRegistry.save(records)
        accounts = records.map(makeSession(for:))
        for session in accounts { session.restore() }
    }

    func enableJev(_ enabled: Bool) throws {
        guard !isOfflinePreview else { throw JevError.missingKey }
        if enabled {
            guard let key = try JevCredentialStore().load() else { throw JevError.missingKey }
            let resolver = try JevCodeResolver(apiKey: key)
            for session in accounts { session.setSemanticResolver(resolver) }
        } else {
            for session in accounts { session.setSemanticResolver(nil) }
        }
        settings.jevEnabled = enabled
        jevProblem = nil
        jevStatus = enabled ? "Jev 已启用，仅处理本地未识别的邮件。" : "仅本地识别，未启用 Jev。"
    }

    func saveJevKey(_ key: String) throws {
        guard !isOfflinePreview else { throw JevError.missingKey }
        try JevCredentialStore().save(key)
        try enableJev(true)
    }

    func importJevKey(from file: URL) throws {
        guard !isOfflinePreview else { throw JevError.missingKey }
        try saveJevKey(JevCredentialStore().importKey(from: file))
    }

    func removeJevKey() throws {
        guard !isOfflinePreview else { throw JevError.missingKey }
        try JevCredentialStore().remove()
        try enableJev(false)
    }

    private func restoreJev() {
        guard settings.jevEnabled else { return }
        do { try enableJev(true) } catch {
            jevProblem = error.localizedDescription
        }
    }

    func select(_ candidate: Candidate) {
        selection.select(candidate.id)
    }

    func moveSelection(by offset: Int) {
        guard !candidates.isEmpty else { return }
        let index = candidates.firstIndex { $0.id == selectedID }
        let next = index.map { min(max($0 + offset, 0), candidates.count - 1) } ?? 0
        selection.select(candidates[next].id)
    }

    func performPrimaryAction(_ id: Candidate.ID) async {
        guard let candidate = candidates.first(where: { $0.id == id }) else {
            status = "这条候选已过期或移除，请查看当前列表。"
            return
        }
        if candidate.isCode {
            _ = await copyCandidate(id)
        } else {
            _ = await openLoginLink(id)
        }
    }

    func performPrimaryAction(at index: Int) {
        guard candidates.indices.contains(index) else { return }
        let id = candidates[index].id
        Task { await performPrimaryAction(id) }
    }

    func performSelectedPrimaryAction() {
        guard let selectedID else { return }
        Task { await performPrimaryAction(selectedID) }
    }

    func setDoNotDisturb(_ choice: DoNotDisturbChoice) async {
        settings.setDoNotDisturb(choice)
        await reconcileDoNotDisturb()
    }

    func resumeDoNotDisturb() async {
        let now = Date()
        if let period = settings.doNotDisturbPeriod {
            arrivals.recordQuietPeriod(period.ending(at: now))
        }
        settings.resumeDoNotDisturb()
        isDoNotDisturbActive = false
        scheduleDoNotDisturbEnd(now: now)
        await refresh()
    }

    func timeOrWakeDidChange(timeZoneChanged: Bool = false) async {
        if timeZoneChanged {
            settings.recalculateDoNotDisturb(using: .current)
        }
        await reconcileDoNotDisturb()
    }

    private func reconcileDoNotDisturb(now: Date = Date()) async {
        let period = settings.doNotDisturbPeriod
        if let period { arrivals.recordQuietPeriod(period) }
        let wasActive = isDoNotDisturbActive
        let active = period?.isActive(at: now) ?? false
        isDoNotDisturbActive = active
        if active && !wasActive { onDoNotDisturbStarted?() }
        if !active, let period, let end = period.endsAt, end <= now {
            settings.resumeDoNotDisturb()
        }
        scheduleDoNotDisturbEnd(now: now)
        await refresh()
    }

    private func scheduleDoNotDisturbEnd(now: Date) {
        doNotDisturbTimer?.cancel()
        doNotDisturbTimer = nil
        guard isDoNotDisturbActive, let end = settings.doNotDisturbPeriod?.endsAt else { return }
        let delay = max(0, end.timeIntervalSince(now))
        doNotDisturbTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.reconcileDoNotDisturb()
        }
    }

    func loadSample() async {
        guard !isBusy, accountRecords.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        uid += 1
        let account = "demo@example.test"
        // Synthetic senders preview the avatar and brand mapping; the subject marks them as offline samples.
        let samples = [
            ("Google <no-reply@accounts.google.com>", "Your Google verification code is 001234"),
            ("GitHub <noreply@github.com>", "Your GitHub launch code is 482913"),
            ("Claude <no-reply@mail.anthropic.com>", "您的验证码为：aB12cD"),
            ("Example · 合成邮件 <demo@example.test>", "Your verification code is 730051"),
        ]
        let (source, body) = samples[Int(uid - 1) % samples.count]
        let codes = CodeDetector().codes(subject: "离线测试邮件", body: body)
        let now = Date()
        await vault.insert(
            message: .init(account: account, mailbox: "INBOX", uidValidity: 1, uid: uid),
            codes: codes, source: source, subject: "离线测试邮件（合成）",
            receivedAt: now, now: now
        )
        await refresh()
        status = "这是离线合成邮件，不是真实收信。连接邮箱时会移除演示候选。"
    }

    func refresh() async {
        guard !isStopping else { return }
        refreshVersion += 1
        let version = refreshVersion
        let now = Date()
        let snapshot = await vault.snapshot(now: now)
        guard version == refreshVersion else { return }
        candidates = snapshot
        selection.reconcile(with: snapshot)
        if let autoFill {
            do {
                let accountIDs = Set(accountRecords.map(\.id))
                try autoFill.replaceCandidates(
                    snapshot.filter { accountIDs.contains($0.id.message.account) && $0.isCode })
                autoFillProblem = nil
            } catch { autoFillProblem = error.localizedDescription }
        }
        scheduleExpiration()
        onCandidateListChanged?()
        if let arrival = arrivals.receive(
            snapshot, now: now, automaticCopyEnabled: settings.automaticallyCopy,
            quietPeriod: settings.doNotDisturbPeriod)
        {
            let automaticCopyCandidateID = arrival.automaticCopy?.id
            let copied = arrival.automaticCopy.map { automaticallyCopyCandidate($0.id, now: now) } ?? false
            let feedback = automaticCopyCandidateID.map { _ in
                copied ? "已自动复制，按 ⌘V 粘贴" : status
            }
            onArrival?(
                ArrivalNotice(
                    candidates: arrival.candidates,
                    automaticCopyCandidateID: automaticCopyCandidateID,
                    automaticallyCopied: copied,
                    automaticCopyFeedback: feedback))
        }
    }

    func copySelection() async {
        guard let id = selectedID else {
            status = "请先选择一条验证码。"
            return
        }
        _ = await copyCandidate(id)
    }

    @discardableResult
    func copyCandidate(_ id: Candidate.ID) async -> Bool {
        let now = Date()
        guard !isStopping, !accounts.contains(where: { $0.phase == .stopping }),
            let candidate = await vault.candidate(id: id, now: now), candidate.isCode,
            candidates.contains(where: { $0.id == id && $0.expiresAt > now })
        else {
            status = "这条验证码已过期或移除，请查看当前候选。"
            return false
        }
        do {
            try clipboard.copy(candidate, now: now, autoClearSeconds: clipboardAutoClearSeconds)
            lastCopiedID = id
            status = "已复制，在目标输入框按 ⌘V 粘贴。剪贴板历史工具可能保留验证码。"
            await consumeCandidateAfterSuccessfulAction(id, now: Date())
            return true
        } catch {
            status = error.localizedDescription
            return false
        }
    }

    private func automaticallyCopyCandidate(_ id: Candidate.ID, now: Date) -> Bool {
        guard !isStopping, !accounts.contains(where: { $0.phase == .stopping }),
            let candidate = candidates.first(where: { $0.id == id && $0.expiresAt > now }),
            candidate.isCode
        else {
            status = "自动复制失败：候选已过期或移除。"
            return false
        }
        do {
            try clipboard.copy(candidate, now: now, autoClearSeconds: clipboardAutoClearSeconds)
            lastCopiedID = id
            status = "已自动复制，在目标输入框按 ⌘V 粘贴。"
            return true
        } catch {
            status = error.localizedDescription
            return false
        }
    }

    private var clipboardAutoClearSeconds: Int? {
        settings.clipboardAutoClearEnabled ? settings.clipboardAutoClearSeconds : nil
    }

    /// The hotkey only selects live code candidates. AX insertion is verified by the destination.
    func fastFillBestCode() async -> ArrivalActionResult? {
        let page = activePageProvider.currentPage()
        let now = Date()
        guard !isStopping,
            let best = CurrentSiteCandidateRanker().bestCode(in: candidates, for: page, now: now)
        else { return nil }
        let destination = try? AccessibilityDestination()
        guard let candidate = await vault.candidate(id: best.id, now: Date()),
            let code = candidate.code, candidate.expiresAt > Date()
        else { return .failed("候选已过期或移除。") }
        if let destination {
            do {
                try destination.insert(code)
                status = "已填入输入框；未提交表单。"
                await consumeCandidateAfterSuccessfulAction(candidate.id, now: Date())
                return .filled
            } catch {
                // An uncertain AX write is never retried. The fallback writes the clipboard once.
            }
        }
        guard await copyCandidate(candidate.id) else { return .failed(status) }
        status = "无法安全填入，已复制；请检查输入框后按 ⌘V 粘贴。"
        return .copiedAfterFailure(status)
    }

    func refetchMissedMail(_ entry: RecentMissedMail) async throws -> ReceivedMail {
        guard !isOfflinePreview,
            accountRecords.contains(where: { $0.id == entry.id.account }),
            let session = accounts.first(where: { $0.account.id == entry.id.account }),
            session.phase != .paused, session.phase != .notConfigured,
            session.phase != .stopping,
            let login = try credentials.load(accountID: entry.id.account)
        else {
            throw IMAPMessageRefetchError.accountMismatch
        }
        return try await GmailMissedMailFetcher(microsoftTokens: microsoftTokenManager)
            .fetchReadOnly(login: login, message: entry.id)
    }

    private func consumeCandidateAfterSuccessfulAction(_ id: Candidate.ID, now: Date) async {
        guard await vault.consume(id: id, afterSuccessfulAction: true, now: now) != nil else {
            await refresh()
            return
        }
        onCandidateConsumed?(id)
        await refresh()
    }

    func fillOrCopy(_ id: Candidate.ID, writableTargetAvailable: Bool) async -> ArrivalActionResult {
        let now = Date()
        let candidate = await vault.candidate(id: id, now: now)
        guard !isStopping, !accounts.contains(where: { $0.phase == .stopping }),
            let candidate,
            candidates.contains(where: { $0.id == id && $0.expiresAt > now })
        else {
            status = "这条验证码已过期或移除，请查看当前候选。"
            return .failed(status)
        }

        if candidate.loginLink != nil {
            return await openLoginLink(id) ? .opened : .failed(status)
        }
        guard let code = candidate.code else {
            status = "候选类型无法处理。"
            return .failed(status)
        }

        let action = settings.actionForCodeCard(writableTargetAvailable: writableTargetAvailable)
        if action == .copy {
            if settings.cardClickAction == .fill {
                guard await copyCandidate(id) else { return .failed(status) }
                let reason = accessibilityPermissionGranted ? "当前没有可安全填入的输入框" : "辅助功能未授权"
                status = "\(reason)，已复制，按 ⌘V 粘贴。"
                return .copiedAfterFailure(status)
            }
            guard await copyCandidate(id) else { return .failed(status) }
            return .copied
        }

        guard accessibilityPermissionGranted else {
            guard await copyCandidate(id) else { return .failed(status) }
            status = "辅助功能未授权，已复制，按 ⌘V 粘贴。"
            return .copiedAfterFailure(status)
        }

        do {
            let destination = try AccessibilityDestination()
            guard candidate.expiresAt > Date() else { throw FillError.expired }
            try destination.insert(code)
            status = "已填入输入框；未提交表单。"
            await consumeCandidateAfterSuccessfulAction(id, now: Date())
            return .filled
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            guard await copyCandidate(id) else { return .failed(status) }
            let feedback: String
            if let failure = error as? AccessibilityDestination.Failure,
                failure == .writeFailed || failure == .unverified
            {
                feedback = "填入未获确认：\(reason) 已复制，按 ⌘V 粘贴；请先检查输入框，不会自动重试。"
            } else {
                feedback = "\(reason) 已复制，按 ⌘V 粘贴。"
            }
            status = feedback
            return .copiedAfterFailure(feedback)
        }
    }

    @discardableResult
    func openLoginLink(_ id: Candidate.ID) async -> Bool {
        let now = Date()
        guard !isStopping, !accounts.contains(where: { $0.phase == .stopping }),
            let candidate = await vault.candidate(id: id, now: now),
            candidate.expiresAt > now, candidates.contains(where: { $0.id == id && $0.expiresAt > now }),
            let link = candidate.loginLink,
            let components = URLComponents(url: link.url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil
        else {
            status = "这条链接候选已过期、移除或格式无效，没有打开浏览器。"
            return false
        }
        guard NSWorkspace.shared.open(link.url) else {
            status = "无法在默认浏览器打开链接。"
            return false
        }
        status = "已在默认浏览器打开链接。"
        await consumeCandidateAfterSuccessfulAction(id, now: Date())
        return true
    }

    func confirmFill() async -> Bool {
        guard let id = selectedID, !isBusy else {
            status = "请先选择验证码。"
            return false
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await fillCoordinator.fill(id)
            await consumeCandidateAfterSuccessfulAction(id, now: Date())
            status = "已核对输入框中的文本；未提交表单。"
            return true
        } catch let error as AccessibilityDestination.Failure {
            status = error.localizedDescription
        } catch let error as FillError {
            switch error {
            case .noTarget: status = "请先对准输入框按 ⌃⌥Space，再选择并确认填入。"
            case .expired: status = "这条候选已超过本地保留窗口，未执行输入。"
            case .cancelled: status = "目标已变更或操作已取消，未执行输入。"
            case .notCode: status = "这条候选是登录链接，不能作为验证码填入。"
            }
        } catch {
            status = "填入未获确认，请检查输入框；不会自动重试。"
        }
        await refresh()
        return false
    }

    func checkPermission() {
        status =
            AXIsProcessTrusted()
            ? "辅助功能已授权；仍需逐个验证目标控件。"
            : "辅助功能尚未授权。需要你在系统设置中允许 Mail Code Filler；当前不会请求或修改权限。"
    }

    func withdrawAutoFill() throws {
        guard supportsAutoFill && !isOfflinePreview else { return }
        guard let autoFill else { throw AutoFillError.missingConfiguration }
        try autoFill.replaceCandidates([])
    }

    func stop() {
        isStopping = true
        refreshVersion += 1
        for session in accounts { session.shutdown() }
        expirationTask?.cancel()
        doNotDisturbTimer?.cancel()
        if supportsAutoFill { fillCoordinator.cancel() }
        clipboard.autoClear.cancel()
        Task {
            await codeWaitController.cancel()
            await recentMissedMail.clear()
        }
    }

    private func scheduleExpiration() {
        expirationTask?.cancel()
        guard let deadline = candidates.map(\.expiresAt).min() else { return }
        let delay = max(0, deadline.timeIntervalSinceNow)
        expirationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                // Sleep only throws on cancellation when the next expiry changes.
                return
            }
            await self?.refresh()
        }
    }
}
