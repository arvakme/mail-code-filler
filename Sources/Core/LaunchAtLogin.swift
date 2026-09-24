import Foundation

public enum LaunchAtLoginStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

@MainActor
public protocol LaunchAtLoginBackend: AnyObject {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
    func openSettings()
}

@MainActor
public protocol LaunchAtLoginManaging: AnyObject {
    func refresh() -> LaunchAtLoginStatus
    @discardableResult func setEnabled(_ enabled: Bool) throws -> LaunchAtLoginStatus
    func openSettings()
}

/// Reads the system after each change; no preference copy of the login-item state exists.
@MainActor
public final class LaunchAtLoginController: LaunchAtLoginManaging {
    private let backend: any LaunchAtLoginBackend

    public init(backend: any LaunchAtLoginBackend) {
        self.backend = backend
    }

    public func refresh() -> LaunchAtLoginStatus { backend.status }

    @discardableResult
    public func setEnabled(_ enabled: Bool) throws -> LaunchAtLoginStatus {
        let status = backend.status
        if enabled {
            if status == .notRegistered || status == .notFound { try backend.register() }
        } else if status != .notRegistered && status != .notFound {
            try backend.unregister()
        }
        return backend.status
    }

    public func openSettings() { backend.openSettings() }
}
