import AppKit
import ApplicationServices
import MailCodeCore

/// Observes foreground focus only while the user has enabled the optional trigger.
@MainActor
final class CodeWaitTriggerMonitor {
    private let controller: any CodeWaitControlling
    private let pageProvider: (any ActivePageProviding)?
    private let requireAuthPage: Bool
    private var observer: AXObserver?
    private var observedApplication: AXUIElement?
    private var activationToken: NSObjectProtocol?
    private(set) var isEnabled = false

    init(
        controller: any CodeWaitControlling,
        pageProvider: (any ActivePageProviding)? = nil,
        requireAuthPage: Bool = false
    ) {
        self.controller = controller
        self.pageProvider = pageProvider
        self.requireAuthPage = requireAuthPage
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            activationToken = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.observeFrontmostApplication() }
            }
            observeFrontmostApplication()
        } else {
            if let activationToken {
                NSWorkspace.shared.notificationCenter.removeObserver(activationToken)
                self.activationToken = nil
            }
            stopObservingApplication()
        }
    }

    private func observeFrontmostApplication() {
        stopObservingApplication()
        guard isEnabled, AXIsProcessTrusted(),
            let application = NSWorkspace.shared.frontmostApplication,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }

        var newObserver: AXObserver?
        let result = AXObserverCreate(
            application.processIdentifier,
            { _, _, _, refcon in
                guard let refcon else { return }
                let monitor = Unmanaged<CodeWaitTriggerMonitor>.fromOpaque(refcon).takeUnretainedValue()
                Task { @MainActor in monitor.handleFocusedChange() }
            }, &newObserver)
        guard result == .success, let newObserver else { return }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        guard
            AXObserverAddNotification(
                newObserver, app, kAXFocusedUIElementChangedNotification as CFString,
                Unmanaged.passUnretained(self).toOpaque()) == .success
        else { return }
        observer = newObserver
        observedApplication = app
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)
        handleFocusedChange()
    }

    private func handleFocusedChange() {
        guard isEnabled, AXIsProcessTrusted() else { return }
        let looksLikeAuthPage: Bool
        if requireAuthPage {
            looksLikeAuthPage = pageProvider?.currentPage()?.looksLikeAuthPage ?? false
        } else {
            looksLikeAuthPage = false
        }
        guard !requireAuthPage || looksLikeAuthPage else { return }
        guard
            WaitingFieldDetector.focusedFieldMatches(
                requireAuthPage: requireAuthPage, looksLikeAuthPage: looksLikeAuthPage)
        else { return }
        Task { await controller.begin(.otpField) }
    }

    private func stopObservingApplication() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            if let observedApplication {
                AXObserverRemoveNotification(
                    observer, observedApplication, kAXFocusedUIElementChangedNotification as CFString)
            }
        }
        observer = nil
        observedApplication = nil
    }

    isolated deinit {
        if let activationToken { NSWorkspace.shared.notificationCenter.removeObserver(activationToken) }
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }
}
