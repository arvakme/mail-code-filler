import Foundation
import Testing

@testable import MailCodeCore

@MainActor
struct FillCoordinatorTests {
    final class Destination: FillDestination {
        var writes: [String] = []
        var fail = false
        func insert(_ code: String) throws {
            writes.append(code)
            if fail { throw Failure.unverified }
        }
    }
    enum Failure: Error { case unverified }

    func fixture() async throws -> (CandidateVault, Candidate) {
        let vault = CandidateVault()
        let now = Date()
        await vault.insert(
            message: .init(account: "example.test", mailbox: "INBOX", uidValidity: 1, uid: 1),
            codes: ["001234"], source: "Example", receivedAt: now, now: now
        )
        return (vault, try #require(await vault.snapshot(now: now).first))
    }

    @Test func doubleConfirmationCannotInsertTwice() async throws {
        let (vault, candidate) = try await fixture()
        let coordinator = FillCoordinator(vault: vault)
        let destination = Destination()
        coordinator.prepare(destination)
        async let first: Void? = try? coordinator.fill(candidate.id)
        async let second: Void? = try? coordinator.fill(candidate.id)
        _ = await (first, second)
        #expect(destination.writes == ["001234"])
    }

    @Test func uncertainWriteIsNotRetried() async throws {
        let (vault, candidate) = try await fixture()
        let coordinator = FillCoordinator(vault: vault)
        let destination = Destination()
        destination.fail = true
        coordinator.prepare(destination)
        await #expect(throws: Failure.self) { try await coordinator.fill(candidate.id) }
        await #expect(throws: FillError.noTarget) { try await coordinator.fill(candidate.id) }
        #expect(destination.writes == ["001234"])
        #expect(await vault.candidate(id: candidate.id, now: Date()) != nil)
    }

    @Test func expiryDuringCandidateLookupDoesNotWrite() async throws {
        let (vault, candidate) = try await fixture()
        var reads = 0
        let coordinator = FillCoordinator(
            vault: vault,
            now: {
                reads += 1
                return reads == 1 ? candidate.receivedAt : candidate.expiresAt
            })
        let destination = Destination()
        coordinator.prepare(destination)
        await #expect(throws: FillError.expired) { try await coordinator.fill(candidate.id) }
        #expect(destination.writes.isEmpty)
    }

    @Test func cancellationAndExpiryDoNotWrite() async throws {
        let (vault, candidate) = try await fixture()
        let coordinator = FillCoordinator(vault: vault)
        let destination = Destination()
        coordinator.prepare(destination)
        coordinator.cancel()
        await #expect(throws: FillError.noTarget) { try await coordinator.fill(candidate.id) }
        let expired = FillCoordinator(vault: vault, now: { candidate.expiresAt })
        expired.prepare(destination)
        await #expect(throws: FillError.expired) {
            try await expired.fill(candidate.id)
        }
        #expect(destination.writes.isEmpty)
    }

    @Test func successfulWriteNeedsExplicitConsumption() async throws {
        let (vault, candidate) = try await fixture()
        let coordinator = FillCoordinator(vault: vault)
        let destination = Destination()
        coordinator.prepare(destination)
        try await coordinator.fill(candidate.id)
        #expect(destination.writes == ["001234"])
        #expect(await vault.candidate(id: candidate.id, now: Date()) != nil)
        _ = await vault.consume(id: candidate.id, afterSuccessfulAction: true, now: Date())
        #expect(await vault.candidate(id: candidate.id, now: Date()) == nil)
    }
}
