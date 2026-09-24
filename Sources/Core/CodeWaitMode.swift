import Foundation

/// Why a short "waiting for a code" window was opened.
public enum CodeWaitTrigger: Sendable, Equatable {
    case manual
    case otpField
}

/// A bounded window during which feeds check for new mail on a faster cadence.
public struct CodeWaitWindow: Sendable, Equatable {
    public let trigger: CodeWaitTrigger
    public let deadline: ContinuousClock.Instant

    public init(trigger: CodeWaitTrigger, deadline: ContinuousClock.Instant) {
        self.trigger = trigger
        self.deadline = deadline
    }
}

/// Shared read side for feeds. The implementation (controller, clock, stream) lives in this file
/// and is owned by the feed worker; the App-side trigger monitor only calls `begin`/`cancel`.
public protocol CodeWaitSignal: Sendable {
    /// The active window, or nil when feeds should use their normal cadence.
    func currentWindow() async -> CodeWaitWindow?
    /// Emits the new window (or nil) whenever it starts, is cancelled, or expires.
    func updates() -> AsyncStream<CodeWaitWindow?>
}

public protocol CodeWaitControlling: CodeWaitSignal {
    /// Opens a window unless one is already active; repeated triggers never extend it.
    func begin(_ trigger: CodeWaitTrigger) async
    func cancel() async
}

/// A process-local, bounded signal shared by all account feeds.
public actor CodeWaitModeController: CodeWaitControlling {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: Sleep
    private let duration: Duration
    private var window: CodeWaitWindow?
    private var expiry: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<CodeWaitWindow?>.Continuation] = [:]

    public init(
        duration: Duration = .seconds(120),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        precondition(duration > .zero)
        self.duration = duration
        self.now = now
        self.sleep = sleep
    }

    public func begin(_ trigger: CodeWaitTrigger) async {
        if let window, window.deadline > now() { return }
        expiry?.cancel()
        let next = CodeWaitWindow(trigger: trigger, deadline: now().advanced(by: duration))
        window = next
        announce(next)
        expiry = Task { [weak self] in
            guard let self else { return }
            do { try await self.sleep(self.duration) } catch { return }
            await self.expire(expected: next.deadline)
        }
    }

    public func cancel() async {
        expiry?.cancel()
        expiry = nil
        guard window != nil else { return }
        window = nil
        announce(nil)
    }

    public func currentWindow() async -> CodeWaitWindow? {
        guard let window else { return nil }
        if window.deadline <= now() {
            await cancel()
            return nil
        }
        return window
    }

    public nonisolated func updates() -> AsyncStream<CodeWaitWindow?> {
        let id = UUID()
        return AsyncStream { continuation in
            Task { await self.add(id, continuation: continuation) }
            continuation.onTermination = { _ in Task { await self.remove(id) } }
        }
    }

    private func add(_ id: UUID, continuation: AsyncStream<CodeWaitWindow?>.Continuation) async {
        observers[id] = continuation
        continuation.yield(await currentWindow())
    }

    private func remove(_ id: UUID) { observers[id] = nil }

    private func expire(expected: ContinuousClock.Instant) async {
        guard window?.deadline == expected else { return }
        let remaining = now().duration(to: expected)
        if remaining > .zero {
            do { try await sleep(remaining) } catch { return }
            await expire(expected: expected)
            return
        }
        window = nil
        expiry = nil
        announce(nil)
    }

    private func announce(_ value: CodeWaitWindow?) {
        for continuation in observers.values { continuation.yield(value) }
    }
}
