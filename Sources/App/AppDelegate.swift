import AppKit
import Darwin
import MailCodeCore
import Network

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    private let lifecycle: AppLifecycle?
    private let launchHandoff: AppHandoff?
    private let waitForProcessID: Int32?
    private let hotKey = HotKey()
    private lazy var panel = PanelController(model: model, pageProvider: model.activePageProvider)
    private lazy var arrivalPanel = ArrivalPanelController(
        model: model, pageProvider: model.activePageProvider)
    private var codeWaitMonitor: CodeWaitTriggerMonitor?
    private var wakeObserver: NSObjectProtocol?
    private var clockObserver: NSObjectProtocol?
    private var timeZoneObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var receivedInitialNetworkPath = false
    private var didLaunch = false

    override init() {
        let arguments = ProcessInfo.processInfo.arguments
        let isOfflinePreview = arguments.contains("--offline-preview")
        let isAgentProcess = arguments.contains("--launch-agent")
        let mode: AppLaunchMode = isAgentProcess ? .agent : .manual
        let lifecycle = isOfflinePreview ? nil : AppLifecycle(preferences: .standard)
        let handoff = lifecycle?.handoff
        let decision = AppLaunchDecision.decide(
            processID: getpid(), runningProcessIDs: Self.runningProcessIDs(), mode: mode,
            handoff: handoff, at: Date())
        if decision == .exit { exit(EXIT_SUCCESS) }
        if case .waitForProcess(let processID) = decision {
            waitForProcessID = processID
        } else {
            waitForProcessID = nil
        }
        self.lifecycle = lifecycle
        launchHandoff =
            handoff?.isValid(for: mode, currentProcessID: getpid(), at: Date()) == true ? handoff : nil
        let backend = SMAppLaunchAtLogin(lifecycle: lifecycle, isAgentProcess: isAgentProcess)
        model = AppModel(
            loginManager: LaunchAtLoginController(
                backend: backend, legacyBackend: SMAppLaunchAtLogin(service: .mainApp),
                allowsChanges: !isOfflinePreview))
        super.init()
        backend.prepareForHandoff = { [weak self] in self?.permitsTermination() ?? false }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let waitForProcessID else {
            finishLaunch()
            return
        }
        // Return to AppKit so NSWorkspace can report a successful launch to the old instance.
        // Accounts, the shutdown marker and global monitors stay untouched until it has exited.
        Task { @MainActor in
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while kill(waitForProcessID, 0) == 0 || errno == EPERM {
                guard ContinuousClock.now < deadline, let launchHandoff,
                    Date() < launchHandoff.expiresAt, lifecycle?.handoff == launchHandoff
                else { exit(EXIT_SUCCESS) }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Self.runningProcessIDs().contains(where: { $0 != getpid() }) else {
                exit(EXIT_SUCCESS)
            }
            finishLaunch()
        }
    }

    private static func runningProcessIDs() -> [Int32] {
        guard let identifier = Bundle.main.bundleIdentifier else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { !$0.isTerminated }.map(\.processIdentifier)
    }

    private func finishLaunch() {
        model.recoveredFromUnexpectedExit =
            lifecycle?.beginLaunch(afterHandoff: launchHandoff != nil) ?? false
        // Global shortcuts stay limited to the optional AutoFill build's chooser; the everyday
        // flow is the arrival card stack plus click-to-fill.
        if model.supportsAutoFill {
            let registered = hotKey.register { [weak self] in self?.panel.show() }
            model.shortcutStatus = registered ? "⌃⌥Space · 选择并填入" : "⌃⌥Space 注册失败，仍可显式复制。"
        }
        model.onCodeWaitTriggerSettingsChanged = { [weak self] in
            self?.configureCodeWaitMonitor()
        }
        configureCodeWaitMonitor()
        model.onScreenshotSettingChanged = { [weak self] allowed in
            guard let self else { return }
            arrivalPanel.updateScreenshotSharing(allowed)
            panel.updateScreenshotSharing(allowed)
        }
        model.onArrival = { [weak self] notice in
            self?.arrivalPanel.show(notice)
        }
        model.onCandidateConsumed = { [weak self] id in self?.arrivalPanel.consumed(id) }
        model.onDoNotDisturbStarted = { [weak self] in self?.arrivalPanel.close() }
        model.onCandidateListChanged = { [weak self] in self?.arrivalPanel.reconcile() }
        model.start()
        startNetworkPathMonitor()
        didLaunch = true
        model.isStarting = false
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                for session in self?.model.accounts ?? [] { session.reconnectAfterWake() }
                Task { await self?.model.timeOrWakeDidChange() }
            }
        }
        clockObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.model.timeOrWakeDidChange() } }
        }
        timeZoneObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.model.timeOrWakeDidChange(timeZoneChanged: true) } }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard didLaunch else { return }
        Task {
            await model.timeOrWakeDidChange()
            await model.refreshAutoFill()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let handoff = lifecycle?.handoff
        let alreadyApproved = handoff?.processID == getpid() && (handoff?.expiresAt ?? .distantPast) > Date()
        guard alreadyApproved || permitsTermination() else {
            lifecycle?.cancelHandoff(processID: getpid())
            return .terminateCancel
        }
        model.stop()
        return .terminateNow
    }

    private func permitsTermination() -> Bool {
        do {
            try model.withdrawAutoFill()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "未能清空系统 AutoFill 验证码"
            alert.informativeText =
                "\(error.localizedDescription)\n\n保留 App 后可重试退出。若仍然退出，旧码可能在邮件接收后 10 分钟内继续被扩展读取。"
            alert.addButton(withTitle: "保留 App")
            alert.addButton(withTitle: "仍然退出")
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        pathMonitor?.cancel()
        pathMonitor = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let clockObserver { NotificationCenter.default.removeObserver(clockObserver) }
        if let timeZoneObserver { NotificationCenter.default.removeObserver(timeZoneObserver) }
        wakeObserver = nil
        clockObserver = nil
        timeZoneObserver = nil
        hotKey.invalidate()
        codeWaitMonitor?.setEnabled(false)
        codeWaitMonitor = nil
        panel.stop()
        arrivalPanel.stop()
        if didLaunch { lifecycle?.recordCleanShutdown() }
    }

    private func configureCodeWaitMonitor() {
        codeWaitMonitor?.setEnabled(false)
        codeWaitMonitor = CodeWaitTriggerMonitor(
            controller: model.codeWaitController,
            pageProvider: model.activePageProvider,
            requireAuthPage: model.settings.otpFieldRequireAuthPage)
        codeWaitMonitor?.setEnabled(model.settings.otpFieldAutoTriggerEnabled)
    }

    private func startNetworkPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.receivedInitialNetworkPath {
                    for session in self.model.accounts { session.reconnectAfterNetworkChange() }
                } else {
                    self.receivedInitialNetworkPath = true
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "dev.zhijie.MailCodeFiller.network-path"))
        pathMonitor = monitor
    }
}
