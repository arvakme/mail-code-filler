import Foundation
import MailCodeCore
import SwiftMail

struct IMAPFeedConfiguration: Sendable {
    var provider: IMAPProviderDescriptor
    var host: String
    var port: Int
    var transportSecurity: MailTransportSecurity
    var retention: TimeInterval
    var futureSkew: TimeInterval
    var catchupLimit: Int
    var maxBodyBytes: Int
    var idleRenewal: Duration
    var livenessInterval: Duration
    var pollInterval: Duration
    var backoff: [Duration]
    var now: @Sendable () -> Date

    static let gmail = production(.gmail)
    static let qqMail = production(.qqMail)

    static func production(_ provider: IMAPProvider) -> IMAPFeedConfiguration {
        let descriptor = provider.descriptor
        return IMAPFeedConfiguration(
            provider: descriptor,
            host: descriptor.host,
            port: descriptor.port,
            transportSecurity: .implicitTLS,
            retention: CandidateVault.retention,
            futureSkew: 120,
            catchupLimit: 30,
            maxBodyBytes: 256 * 1024,
            // Renewal is a bounded catchup if IDLE misses an event. It stays
            // inside CandidateVault.retention for both current providers.
            idleRenewal: .seconds(5 * 60),
            livenessInterval: .seconds(60),
            pollInterval: .seconds(10),
            backoff: [.seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(30)],
            now: Date.init)
    }

    /// Local script-server settings. The fixture never changes production TLS verification.
    static func testing(
        port: Int,
        provider: IMAPProvider = .gmail,
        now: @escaping @Sendable () -> Date,
        retention: TimeInterval = CandidateVault.retention,
        catchupLimit: Int = 30,
        maxBodyBytes: Int = 64 * 1024,
        idleRenewal: Duration = .seconds(30),
        livenessInterval: Duration = .seconds(60),
        pollInterval: Duration = .milliseconds(100),
        backoff: [Duration] = [.milliseconds(50)]
    ) -> IMAPFeedConfiguration {
        IMAPFeedConfiguration(
            provider: provider.descriptor,
            host: "127.0.0.1",
            port: port,
            transportSecurity: .plainText,
            retention: retention,
            futureSkew: 120,
            catchupLimit: catchupLimit,
            maxBodyBytes: maxBodyBytes,
            idleRenewal: idleRenewal,
            livenessInterval: livenessInterval,
            pollInterval: pollInterval,
            backoff: backoff,
            now: now)
    }
}

typealias GmailIMAPConfiguration = IMAPFeedConfiguration
