import Testing

@testable import MailCodeCore

@MainActor
struct LaunchAtLoginTests {
    final class Backend: LaunchAtLoginBackend {
        enum Failure: Error { case unavailable }
        var status: LaunchAtLoginStatus = .notRegistered
        var shouldFail = false
        var registerCalls = 0
        var unregisterCalls = 0
        var openedSettings = false

        func register() throws {
            registerCalls += 1
            if shouldFail { throw Failure.unavailable }
            status = .requiresApproval
        }

        func unregister() throws {
            unregisterCalls += 1
            if shouldFail { throw Failure.unavailable }
            status = .notRegistered
        }

        func openSettings() { openedSettings = true }
    }

    @Test func readsLiveStatusAndRegistersOnlyWhenNeeded() throws {
        let backend = Backend()
        let controller = LaunchAtLoginController(backend: backend)
        #expect(controller.refresh() == .notRegistered)
        #expect(try controller.setEnabled(true) == .requiresApproval)
        #expect(backend.registerCalls == 1)
        backend.status = .enabled
        #expect(controller.refresh() == .enabled)
        #expect(try controller.setEnabled(true) == .enabled)
        #expect(backend.registerCalls == 1)
        #expect(try controller.setEnabled(false) == .notRegistered)
        #expect(backend.unregisterCalls == 1)
        controller.openSettings()
        #expect(backend.openedSettings)
    }

    @Test func errorsDoNotInventAnEnabledState() {
        let backend = Backend()
        backend.shouldFail = true
        let controller = LaunchAtLoginController(backend: backend)
        #expect(throws: Backend.Failure.unavailable) { try controller.setEnabled(true) }
        #expect(controller.refresh() == .notRegistered)
        backend.status = .requiresApproval
        #expect(throws: Backend.Failure.unavailable) { try controller.setEnabled(false) }
        #expect(controller.refresh() == .requiresApproval)
    }

    @Test func missingRegistrationCanBeRepaired() throws {
        let backend = Backend()
        backend.status = .notFound
        #expect(try LaunchAtLoginController(backend: backend).setEnabled(true) == .requiresApproval)
        #expect(backend.registerCalls == 1)
    }
}
