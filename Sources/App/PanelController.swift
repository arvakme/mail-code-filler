import AppKit
import SwiftUI

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let panel: NSPanel
    private var activationObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 440),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        super.init()
        panel.title = "选择验证码"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.sharingType = model.settings.allowsScreenshots ? .readOnly : .none
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: CandidatePanel(model: model, close: { [weak self] in self?.close() }))
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                self.model.status = "前台 App 已变化，填入操作已取消。"
                self.close()
            }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func show() {
        close()
        updateScreenshotSharing()
        do {
            let destination = try AccessibilityDestination()
            model.fillCoordinator.prepare(destination)
            model.targetName = destination.application.localizedName ?? "原输入 App"
            model.status = "选择后才会插入，不会提交表单。"
        } catch {
            model.status = error.localizedDescription
        }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func updateScreenshotSharing(_ allowed: Bool? = nil) {
        let isAllowed = allowed ?? model.settings.allowsScreenshots
        panel.sharingType = isAllowed ? .readOnly : .none
    }

    func close() {
        model.fillCoordinator.cancel()
        model.targetName = nil
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    func stop() {
        close()
        for observer in [activationObserver, sleepObserver].compactMap({ $0 }) {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        activationObserver = nil
        sleepObserver = nil
    }
}
