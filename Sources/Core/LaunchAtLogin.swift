import Foundation

public enum LaunchAtLoginStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

public enum LaunchAtLoginError: Error {
    case changesDisabled
}

@MainActor
public protocol LaunchAtLoginBackend: AnyObject {
    var status: LaunchAtLoginStatus { get }
    func register() async throws
    func unregister() async throws
    func finishChanges()
    func openSettings()
}

extension LaunchAtLoginBackend {
    public func finishChanges() {}
}

@MainActor
public protocol LaunchAtLoginManaging: AnyObject {
    var status: LaunchAtLoginStatus { get }
    var hasError: Bool { get }
    func refresh() async -> LaunchAtLoginStatus
    @discardableResult func setEnabled(_ enabled: Bool) async throws -> LaunchAtLoginStatus
    func openSettings()
}

/// Reads the system after each change; no preference copy of the login-item state exists.
@MainActor
public final class LaunchAtLoginController: LaunchAtLoginManaging {
    private let backend: any LaunchAtLoginBackend
    private let legacyBackend: (any LaunchAtLoginBackend)?
    private let allowsChanges: Bool
    public private(set) var hasError = false
    public var status: LaunchAtLoginStatus { backend.status }

    public init(
        backend: any LaunchAtLoginBackend,
        legacyBackend: (any LaunchAtLoginBackend)? = nil,
        allowsChanges: Bool = true
    ) {
        self.backend = backend
        self.legacyBackend = legacyBackend
        self.allowsChanges = allowsChanges
    }

    public func refresh() async -> LaunchAtLoginStatus {
        guard allowsChanges else { return backend.status }
        defer { backend.finishChanges() }
        do {
            try await migrateLegacyRegistration()
            hasError = false
        } catch {
            hasError = true
        }
        return backend.status
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool) async throws -> LaunchAtLoginStatus {
        guard allowsChanges else { throw LaunchAtLoginError.changesDisabled }
        defer { backend.finishChanges() }
        do {
            if enabled {
                try await migrateLegacyRegistration()
                if backend.status == .notRegistered || backend.status == .notFound {
                    try await backend.register()
                }
            } else {
                if let legacyBackend, isRegistered(legacyBackend.status) {
                    try await legacyBackend.unregister()
                }
                if isRegistered(backend.status) { try await backend.unregister() }
            }
            hasError = false
            return backend.status
        } catch {
            hasError = true
            throw error
        }
    }

    public func openSettings() {
        if allowsChanges { backend.openSettings() }
    }

    private func migrateLegacyRegistration() async throws {
        guard let legacyBackend, isRegistered(legacyBackend.status) else { return }
        // Keep the existing login item until its replacement has registered successfully.
        if !isRegistered(backend.status) { try await backend.register() }
        if isRegistered(legacyBackend.status) { try await legacyBackend.unregister() }
    }

    private func isRegistered(_ status: LaunchAtLoginStatus) -> Bool {
        status == .enabled || status == .requiresApproval
    }
}
