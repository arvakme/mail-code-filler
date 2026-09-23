import AppKit
import Network

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private let hotKey = HotKey()
    private lazy var panel = PanelController(model: model)
    private lazy var arrivalPanel = ArrivalPanelController(model: model)
    private var wakeObserver: NSObjectProtocol?
    private var clockObserver: NSObjectProtocol?
    private var timeZoneObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var receivedInitialNetworkPath = false
    private var didLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if model.supportsAutoFill {
            let registered = hotKey.register { [weak self] in self?.panel.show() }
            model.shortcutStatus =
                registered ? "⌃⌥Space · 选择并填入" : "⌃⌥Space 注册失败，仍可显式复制。"
        }
        model.onScreenshotSettingChanged = { [weak self] allowed in
            guard let self else { return }
            arrivalPanel.updateScreenshotSharing(allowed)
            if model.supportsAutoFill { panel.updateScreenshotSharing(allowed) }
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
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        model.stop()
        return .terminateNow
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
        if model.supportsAutoFill { panel.stop() }
        arrivalPanel.stop()
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
