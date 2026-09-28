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

    @Test func readsLiveStatusAndRegistersOnlyWhenNeeded() async throws {
        let backend = Backend()
        let controller = LaunchAtLoginController(backend: backend)
        #expect(await controller.refresh() == .notRegistered)
        #expect(try await controller.setEnabled(true) == .requiresApproval)
        #expect(backend.registerCalls == 1)
        backend.status = .enabled
        #expect(await controller.refresh() == .enabled)
        #expect(try await controller.setEnabled(true) == .enabled)
        #expect(backend.registerCalls == 1)
        #expect(try await controller.setEnabled(false) == .notRegistered)
        #expect(backend.unregisterCalls == 1)
        controller.openSettings()
        #expect(backend.openedSettings)
    }

    @Test func errorsDoNotInventAnEnabledState() async {
        let backend = Backend()
        backend.shouldFail = true
        let controller = LaunchAtLoginController(backend: backend)
        await #expect(throws: Backend.Failure.unavailable) { try await controller.setEnabled(true) }
        #expect(await controller.refresh() == .notRegistered)
        backend.status = .requiresApproval
        await #expect(throws: Backend.Failure.unavailable) { try await controller.setEnabled(false) }
        #expect(await controller.refresh() == .requiresApproval)
    }

    @Test func missingRegistrationCanBeRepaired() async throws {
        let backend = Backend()
        backend.status = .notFound
        #expect(try await LaunchAtLoginController(backend: backend).setEnabled(true) == .requiresApproval)
        #expect(backend.registerCalls == 1)
    }

    @Test(arguments: [LaunchAtLoginStatus.enabled, .requiresApproval])
    func migratesExistingLoginItemWithoutLosingApprovalState(legacyStatus: LaunchAtLoginStatus) async {
        let agent = Backend()
        let legacy = Backend()
        legacy.status = legacyStatus
        let controller = LaunchAtLoginController(backend: agent, legacyBackend: legacy)

        #expect(await controller.refresh() == .requiresApproval)
        #expect(legacy.status == .notRegistered)
        #expect(!controller.hasError)
        #expect(await controller.refresh() == .requiresApproval)
        #expect(agent.registerCalls == 1)
        #expect(legacy.unregisterCalls == 1)
    }

    @Test func failedMigrationPreservesExistingLoginItemAndCanRetry() async {
        let agent = Backend()
        let legacy = Backend()
        legacy.status = .enabled
        agent.shouldFail = true
        let controller = LaunchAtLoginController(backend: agent, legacyBackend: legacy)

        #expect(await controller.refresh() == .notRegistered)
        #expect(controller.hasError)
        #expect(legacy.status == .enabled)
        agent.shouldFail = false
        #expect(await controller.refresh() == .requiresApproval)
        #expect(!controller.hasError)
        #expect(legacy.status == .notRegistered)
    }

    @Test func migrationRetriesOnlyLegacyRemovalWhenAgentAlreadyExists() async {
        let agent = Backend()
        let legacy = Backend()
        agent.status = .enabled
        legacy.status = .enabled
        legacy.shouldFail = true
        let controller = LaunchAtLoginController(backend: agent, legacyBackend: legacy)

        #expect(await controller.refresh() == .enabled)
        #expect(controller.hasError)
        #expect(agent.registerCalls == 0)
        legacy.shouldFail = false
        #expect(await controller.refresh() == .enabled)
        #expect(!controller.hasError)
        #expect(legacy.status == .notRegistered)
        #expect(agent.registerCalls == 0)
    }

    @Test func disablingBeforeMigrationRemovesBothRegistrationsWithoutEnablingAgent() async throws {
        let agent = Backend()
        let legacy = Backend()
        legacy.status = .enabled
        let controller = LaunchAtLoginController(backend: agent, legacyBackend: legacy)

        #expect(try await controller.setEnabled(false) == .notRegistered)
        #expect(legacy.status == .notRegistered)
        #expect(agent.registerCalls == 0)
        #expect(await controller.refresh() == .notRegistered)
        #expect(agent.registerCalls == 0)
    }

    @Test func freshInstallationDoesNotOptIntoLoginOrRecovery() async {
        let agent = Backend()
        let legacy = Backend()
        let controller = LaunchAtLoginController(backend: agent, legacyBackend: legacy)

        #expect(await controller.refresh() == .notRegistered)
        #expect(agent.registerCalls == 0)
        #expect(legacy.unregisterCalls == 0)
    }

    @Test func offlinePreviewCannotRegisterOrMigrateLoginItems() async {
        let agent = Backend()
        let legacy = Backend()
        legacy.status = .enabled
        let controller = LaunchAtLoginController(
            backend: agent, legacyBackend: legacy, allowsChanges: false)

        #expect(await controller.refresh() == .notRegistered)
        await #expect(throws: (any Error).self) { try await controller.setEnabled(true) }
        await #expect(throws: (any Error).self) { try await controller.setEnabled(false) }
        #expect(agent.registerCalls == 0)
        #expect(agent.unregisterCalls == 0)
        #expect(legacy.status == .enabled)
        controller.openSettings()
        #expect(!agent.openedSettings)
    }
}
