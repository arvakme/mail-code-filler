import Darwin
import Foundation
import Testing

@testable import MailCodeCore

@Suite("Microsoft loopback authorization", .serialized)
@MainActor
struct MicrosoftOAuthLoopbackListenerTests {
    @Test func successBindsLoopbackOnBothFamiliesAndRejectsSecondRequest() async throws {
        let listener = MicrosoftOAuthLoopbackListener(expectedState: "expected")
        let uri = try listener.start()
        defer { listener.cancel() }
        let components = try #require(URLComponents(string: uri))
        let port = try #require(components.port)
        #expect(components.host == "localhost")
        #expect(port > 0)
        // Browsers may resolve localhost to ::1; both loopback families must accept.
        #expect(canConnectIPv6(port: port))
        let other = try await request("http://127.0.0.1:\(port)/favicon.ico")
        #expect(other.status == 404)
        let empty = try await request("http://127.0.0.1:\(port)/")
        #expect(empty.status == 404)
        let response = try await request("http://127.0.0.1:\(port)/?code=synthetic-code&state=expected")
        #expect(response.status == 200)
        #expect(response.body.contains("已登录，可以关闭这个页面并回到 Mail Code Filler。"))
        #expect(try await listener.waitForCode() == "synthetic-code")
        await #expect(throws: (any Error).self) {
            _ = try await request("http://127.0.0.1:\(port)/?code=second&state=expected")
        }
    }

    @Test func redirectOverIPv6LoopbackCompletes() async throws {
        let listener = MicrosoftOAuthLoopbackListener(expectedState: "expected")
        let uri = try listener.start()
        defer { listener.cancel() }
        let port = try #require(URLComponents(string: uri)?.port)
        let response = try await request("http://[::1]:\(port)/?code=v6-code&state=expected")
        #expect(response.status == 200)
        #expect(try await listener.waitForCode() == "v6-code")
    }

    @Test func mismatchedStateAndProviderErrorFailWithChinesePage() async throws {
        let mismatch = MicrosoftOAuthLoopbackListener(expectedState: "expected")
        let mismatchURI = try mismatch.start()
        let bad = try await request("\(mismatchURI)/?code=synthetic-code&state=wrong")
        #expect(bad.status == 200)
        #expect(bad.body.contains("登录未完成"))
        await #expect(throws: MicrosoftOAuthError.invalidCallback) {
            try await mismatch.waitForCode()
        }

        let failure = MicrosoftOAuthLoopbackListener(expectedState: "expected")
        let failureURI = try failure.start()
        let denied = try await request("\(failureURI)/?error=access_denied&state=expected")
        #expect(denied.status == 200)
        #expect(denied.body.contains("登录未完成"))
        await #expect(throws: MicrosoftOAuthError.authorizationFailed) {
            try await failure.waitForCode()
        }
    }

    @Test func timeoutAndCancelStopListening() async throws {
        let timed = MicrosoftOAuthLoopbackListener(expectedState: "expected", timeout: .milliseconds(50))
        let uri = try timed.start()
        await #expect(throws: MicrosoftOAuthError.authorizationFailed) {
            try await timed.waitForCode()
        }
        await #expect(throws: (any Error).self) { _ = try await request("\(uri)/") }

        let cancelled = MicrosoftOAuthLoopbackListener(expectedState: "expected")
        let cancelledURI = try cancelled.start()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelled.waitForCode()
        }
        await #expect(throws: (any Error).self) { _ = try await request("\(cancelledURI)/") }
    }

    private func request(_ string: String) async throws -> (status: Int, body: String) {
        let (data, response) = try await URLSession.shared.data(from: URL(string: string)!)
        return ((response as! HTTPURLResponse).statusCode, String(decoding: data, as: UTF8.self))
    }

    private func canConnectIPv6(port: Int) -> Bool {
        let fd = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = UInt16(port).bigEndian
        address.sin6_addr = in6addr_loopback
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
            }
        }
    }
}
