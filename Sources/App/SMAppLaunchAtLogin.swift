import AppKit
import MailCodeCore
import ServiceManagement

@MainActor
final class SMAppLaunchAtLogin: LaunchAtLoginBackend {
    static let plistName = "dev.zhijie.MailCodeFiller.agent.plist"
    private let service: SMAppService
    private let lifecycle: AppLifecycle?
    private let isAgentProcess: Bool
    private var shouldCompleteHandoff = false
    var prepareForHandoff: (() -> Bool)?

    init(
        service: SMAppService = .agent(plistName: plistName),
        lifecycle: AppLifecycle? = nil, isAgentProcess: Bool = false
    ) {
        self.service = service
        self.lifecycle = lifecycle
        self.isAgentProcess = isAgentProcess
    }

    var status: LaunchAtLoginStatus {
        switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .notRegistered
        @unknown default: .notFound
        }
    }

    func register() async throws {
        guard !ProcessInfo.processInfo.arguments.contains("--offline-preview") else {
            throw LaunchAtLoginError.changesDisabled
        }
        guard service.status == .notRegistered || service.status == .notFound else { return }
        guard let lifecycle, !isAgentProcess else {
            try service.register()
            return
        }
        guard prepareForHandoff?() == true else { throw HandoffError.cancelled }
        lifecycle.prepareHandoff(processID: getpid(), destination: .agent)
        do {
            try service.register()
            if service.status == .enabled {
                shouldCompleteHandoff = true
            } else {
                lifecycle.cancelHandoff(processID: getpid())
            }
        } catch {
            lifecycle.cancelHandoff(processID: getpid())
            throw error
        }
    }

    func unregister() async throws {
        guard !ProcessInfo.processInfo.arguments.contains("--offline-preview") else {
            throw LaunchAtLoginError.changesDisabled
        }
        guard service.status == .enabled || service.status == .requiresApproval else { return }
        guard let lifecycle, isAgentProcess else {
            try await service.unregister()
            return
        }
        guard prepareForHandoff?() == true else { throw HandoffError.cancelled }
        let handoff = lifecycle.prepareHandoff(processID: getpid(), destination: .manual)
        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.activates = false
            configuration.arguments = ["--handoff"]
            let replacementPID = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Int32, any Error>) in
                NSWorkspace.shared.openApplication(
                    at: Bundle.main.bundleURL, configuration: configuration
                ) { application, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let application, !application.isTerminated {
                        continuation.resume(returning: application.processIdentifier)
                    } else {
                        continuation.resume(throwing: HandoffError.launchFailed)
                    }
                }
            }
            guard Date() < handoff.expiresAt, kill(replacementPID, 0) == 0 else {
                throw HandoffError.launchFailed
            }
            // unregister kills a running agent: its replacement is already launched and waiting.
            try await service.unregister()
        } catch {
            lifecycle.cancelHandoff(processID: getpid())
            throw error
        }
    }

    func finishChanges() {
        guard shouldCompleteHandoff else { return }
        shouldCompleteHandoff = false
        // Complete legacy removal before the normal termination callback can end this process.
        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }

    private enum HandoffError: Error {
        case cancelled
        case launchFailed
    }
}
