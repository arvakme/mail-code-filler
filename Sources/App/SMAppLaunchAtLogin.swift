import MailCodeCore
import ServiceManagement

@MainActor
final class SMAppLaunchAtLogin: LaunchAtLoginBackend {
    private var service: SMAppService { .mainApp }

    var status: LaunchAtLoginStatus {
        switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .notRegistered
        @unknown default: .notFound
        }
    }

    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
