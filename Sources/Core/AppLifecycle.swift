import Foundation

public enum AppLaunchMode: String, Codable, Sendable {
    case manual
    case agent
}

public struct AppHandoff: Codable, Equatable, Sendable {
    public let processID: Int32
    public let destination: AppLaunchMode
    public let expiresAt: Date

    public init(processID: Int32, destination: AppLaunchMode, at date: Date) {
        self.processID = processID
        self.destination = destination
        expiresAt = date.addingTimeInterval(10)
    }

    public func isValid(for mode: AppLaunchMode, currentProcessID: Int32, at date: Date) -> Bool {
        let remaining = expiresAt.timeIntervalSince(date)
        return processID > 0 && processID != currentProcessID && destination == mode
            && remaining > 0 && remaining <= 10
    }
}

public enum AppLaunchDecision: Equatable, Sendable {
    case start
    case exit
    case waitForProcess(Int32)

    public static func decide(
        processID: Int32, runningProcessIDs: [Int32], mode: AppLaunchMode,
        handoff: AppHandoff?, at date: Date
    ) -> Self {
        let otherProcesses = runningProcessIDs.filter { $0 != processID }
        guard !otherProcesses.isEmpty else { return .start }
        if let handoff, handoff.isValid(for: mode, currentProcessID: processID, at: date),
            otherProcesses.allSatisfy({ $0 == handoff.processID })
        {
            return .waitForProcess(handoff.processID)
        }
        return .exit
    }
}

public final class AppLifecycle {
    public static let cleanShutdownKey = "dev.zhijie.MailCodeFiller.cleanShutdown"
    private static let handoffKey = "dev.zhijie.MailCodeFiller.handoff"
    private let preferences: UserDefaults

    public init(preferences: UserDefaults) {
        self.preferences = preferences
    }

    public var handoff: AppHandoff? {
        preferences.synchronize()
        guard let data = preferences.data(forKey: Self.handoffKey) else { return nil }
        return try? PropertyListDecoder().decode(AppHandoff.self, from: data)
    }

    @discardableResult
    public func prepareHandoff(
        processID: Int32, destination: AppLaunchMode, at date: Date = Date()
    ) -> AppHandoff {
        let handoff = AppHandoff(processID: processID, destination: destination, at: date)
        preferences.set(try? PropertyListEncoder().encode(handoff), forKey: Self.handoffKey)
        preferences.synchronize()
        return handoff
    }

    public func cancelHandoff(processID: Int32) {
        guard handoff?.processID == processID else { return }
        preferences.removeObject(forKey: Self.handoffKey)
        preferences.synchronize()
    }

    public func beginLaunch(afterHandoff: Bool = false) -> Bool {
        preferences.synchronize()
        let recovered =
            !afterHandoff && preferences.object(forKey: Self.cleanShutdownKey) as? Bool == false
        preferences.set(false, forKey: Self.cleanShutdownKey)
        preferences.removeObject(forKey: Self.handoffKey)
        // Flush at lifecycle boundaries so an immediate crash/exit cannot lose the marker.
        preferences.synchronize()
        return recovered
    }

    public func recordCleanShutdown() {
        preferences.set(true, forKey: Self.cleanShutdownKey)
        preferences.synchronize()
    }
}
