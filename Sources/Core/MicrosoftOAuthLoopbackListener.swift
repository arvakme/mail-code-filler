import Darwin
import Foundation

/// One authorization attempt. Listens on the same port on 127.0.0.1 and ::1 only: browsers
/// often resolve `localhost` to ::1 first, and an IPv4-only socket then refuses the redirect.
@MainActor
public final class MicrosoftOAuthLoopbackListener {
    private let expectedState: String
    private let timeout: Duration
    private var sockets: [Int32] = []
    private var continuation: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    private var timer: Task<Void, Never>?

    public private(set) var redirectURI: String?

    public init(expectedState: String, timeout: Duration = .seconds(300)) {
        self.expectedState = expectedState
        self.timeout = timeout
    }

    public func start() throws -> String {
        guard sockets.isEmpty, redirectURI == nil else { throw MicrosoftOAuthError.authorizationFailed }
        // The IPv4 port is OS-assigned; retry a few times if ::1 happens to have it taken.
        var opened: (v4: Int32, v6: Int32, port: UInt16)?
        for _ in 0..<5 {
            guard let (v4, port) = Self.listenIPv4() else { break }
            if let v6 = Self.listenIPv6(port: port) {
                opened = (v4, v6, port)
                break
            }
            Darwin.close(v4)
        }
        guard let opened else { throw MicrosoftOAuthError.authorizationFailed }
        sockets = [opened.v4, opened.v6]
        let uri = "http://localhost:\(opened.port)"
        redirectURI = uri
        let state = expectedState
        let duration = timeout
        for fd in sockets {
            DispatchQueue.global(qos: .userInitiated).async { @Sendable [weak self] in
                while true {
                    let client = Darwin.accept(fd, nil, nil)
                    if client < 0 { return }
                    let outcome = Self.handle(client, expectedState: state)
                    if case .complete(let result) = outcome {
                        Task { @MainActor [weak self] in self?.finish(result.mapError { $0 as Error }) }
                        return
                    }
                }
            }
        }
        timer = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.finish(.failure(MicrosoftOAuthError.authorizationFailed))
        }
        return uri
    }

    private nonisolated static func listenIPv4() -> (Int32, UInt16)? {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: in_addr_t(0x7f00_0001).bigEndian)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &length) }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0, named == 0 else {
            Darwin.close(fd)
            return nil
        }
        return (fd, UInt16(bigEndian: address.sin_port))
    }

    private nonisolated static func listenIPv6(port: UInt16) -> Int32? {
        let fd = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var v6Only: Int32 = 1
        _ = Darwin.setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6Only, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = in6addr_loopback
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    public func waitForCode() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let result {
                    self.result = nil
                    continuation.resume(with: result)
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    public func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ value: Result<String, Error>) {
        guard !sockets.isEmpty else { return }
        for fd in sockets {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        sockets = []
        timer?.cancel()
        timer = nil
        if let continuation {
            self.continuation = nil
            continuation.resume(with: value)
        } else {
            result = value
        }
    }

    private enum Outcome {
        case ignore
        case complete(Result<String, MicrosoftOAuthError>)
    }

    private nonisolated static func handle(_ client: Int32, expectedState: String) -> Outcome {
        defer { Darwin.close(client) }
        var noSignal: Int32 = 1
        withUnsafePointer(to: &noSignal) {
            _ = Darwin.setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var receiveTimeout = timeval(tv_sec: 2, tv_usec: 0)
        withUnsafePointer(to: &receiveTimeout) {
            _ = Darwin.setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        var bytes = [UInt8](repeating: 0, count: 2048)
        var request = Data()
        let headerEnd = Data("\r\n\r\n".utf8)
        while request.count < 8192, request.range(of: headerEnd) == nil {
            let count = bytes.withUnsafeMutableBytes { Darwin.recv(client, $0.baseAddress, $0.count, 0) }
            if count <= 0 { break }
            request.append(contentsOf: bytes[..<count])
        }
        guard request.range(of: headerEnd) != nil else {
            respond(client, status: "404 Not Found", message: "页面不存在。")
            return .ignore
        }
        guard let line = String(data: request, encoding: .utf8)?.components(separatedBy: "\r\n").first
        else {
            respond(client, status: "404 Not Found", message: "页面不存在。")
            return .ignore
        }
        let parts = line.split(separator: " ").map(String.init)
        guard
            parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/"),
            parts[1].hasPrefix("/"),
            let url = URLComponents(string: "http://localhost\(parts[1])")
        else {
            respond(client, status: "404 Not Found", message: "页面不存在。")
            return .ignore
        }
        guard url.path == "/" else {
            respond(client, status: "404 Not Found", message: "页面不存在。")
            return .ignore
        }
        let state = url.queryItems?.filter { $0.name == "state" } ?? []
        let code = url.queryItems?.filter { $0.name == "code" } ?? []
        let error = url.queryItems?.filter { $0.name == "error" } ?? []
        guard !code.isEmpty || !error.isEmpty else {
            respond(client, status: "404 Not Found", message: "页面不存在。")
            return .ignore
        }
        let outcome: Result<String, MicrosoftOAuthError>
        if state.count == 1, state[0].value == expectedState,
            code.count == 1, let value = code[0].value, !value.isEmpty, error.isEmpty
        {
            outcome = .success(value)
            respond(client, status: "200 OK", message: "已登录，可以关闭这个页面并回到 Mail Code Filler。")
        } else {
            outcome = .failure(error.isEmpty ? .invalidCallback : .authorizationFailed)
            respond(client, status: "200 OK", message: "登录未完成，请关闭这个页面并回到 Mail Code Filler 重试。")
        }
        return .complete(outcome)
    }

    private nonisolated static func respond(_ client: Int32, status: String, message: String) {
        let html = """
            <!doctype html><html lang="zh-CN"><meta charset="utf-8">
            <title>Microsoft 登录</title><body><p>\(message)</p></body></html>
            """
        let body = Data(html.utf8)
        let header = [
            "HTTP/1.1 \(status)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "Connection: close",
            "Content-Security-Policy: default-src 'none'",
            "", "",
        ].joined(separator: "\r\n")
        let response = Data(header.utf8) + body
        response.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var sent = 0
            while sent < buffer.count {
                let count = Darwin.send(client, base.advanced(by: sent), buffer.count - sent, 0)
                if count <= 0 { break }
                sent += count
            }
        }
    }
}
