import Foundation

@MainActor
public protocol FillDestination: AnyObject {
    /// Must validate the captured focus and selection immediately before a single insertion.
    func insert(_ code: String) throws
}

public enum FillError: Error, Equatable {
    case noTarget
    case expired
    case cancelled
    case notCode
}

@MainActor
public final class FillCoordinator {
    private let vault: CandidateVault
    private let now: () -> Date
    private var destination: (any FillDestination)?
    private var intent = UUID()

    public init(vault: CandidateVault, now: @escaping () -> Date = Date.init) {
        self.vault = vault
        self.now = now
    }

    public func prepare(_ destination: any FillDestination) {
        cancel()
        self.destination = destination
    }

    public func cancel() {
        destination = nil
        intent = UUID()
    }

    public func fill(_ id: Candidate.ID) async throws {
        guard let destination else { throw FillError.noTarget }
        let requestedIntent = intent
        let candidate = await vault.candidate(id: id, now: now())
        guard requestedIntent == intent else { throw FillError.cancelled }
        // Clear the captured target before writing; callers consume the candidate only on success.
        cancel()
        guard let candidate, candidate.expiresAt > now() else { throw FillError.expired }
        guard let code = candidate.code else { throw FillError.notCode }
        try destination.insert(code)
    }
}
