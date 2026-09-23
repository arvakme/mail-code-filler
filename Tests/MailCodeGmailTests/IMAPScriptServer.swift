import Darwin
import Foundation

struct ScriptMessage: Sendable {
    var uid: UInt32
    var subject: String
    var from: String
    var internalDate: Date
    var envelopeDate: String
    var mime: String
    var charset: String
    var transferEncoding: String
    var body: Data
    /// Second body of a multipart/alternative message. Nil keeps a single-part structure.
    var htmlBody: Data? = nil
    /// BODYSTRUCTURE octet count when it should disagree with `body`.
    var declaredOctets: Int? = nil
}

/// Local IMAP fixture. Listens on 127.0.0.1 only. LOGIN arguments are not stored.
final class IMAPScriptServer: @unchecked Sendable {
    private let lock = NSLock()
    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientFds: Set<Int32> = []
    private var idleFds: Set<Int32> = []
    private var stopped = false
    private var commandLogStorage: [String] = []
    private var acceptedStorage = 0
    private var loginMatches = 0
    private var logWaiters: [SignalGate] = []

    private var uidValidity: UInt32
    private var messages: [ScriptMessage]
    private let capabilities: [String]
    private let examineReadOnly: Bool
    private let loginSucceeds: Bool
    private let rejectBodyFetch: Bool
    private let rejectDone: Bool
    private let silenceNoop: Bool
    /// LOGIN OK carries the pre-auth capability code and omits IDLE.
    private let loginOmitsIdle: Bool
    let username: String
    let password: String

    private(set) var port: Int = 0

    init(
        username: String,
        password: String,
        uidValidity: UInt32 = 1,
        messages: [ScriptMessage] = [],
        capabilities: [String] = ["IMAP4rev1", "IDLE"],
        examineReadOnly: Bool = true,
        loginSucceeds: Bool = true,
        rejectBodyFetch: Bool = false,
        rejectDone: Bool = false,
        silenceNoop: Bool = false,
        loginOmitsIdle: Bool = false
    ) {
        self.username = username
        self.password = password
        self.uidValidity = uidValidity
        self.messages = messages
        self.capabilities = capabilities
        self.examineReadOnly = examineReadOnly
        self.loginSucceeds = loginSucceeds
        self.rejectBodyFetch = rejectBodyFetch
        self.rejectDone = rejectDone
        self.silenceNoop = silenceNoop
        self.loginOmitsIdle = loginOmitsIdle
    }

    func start() throws {
        lock.lock()
        stopped = false
        commandLogStorage.removeAll()
        acceptedStorage = 0
        loginMatches = 0
        lock.unlock()

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ScriptServerError("socket failed") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw ScriptServerError("bind failed \(errno)")
        }
        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        port = Int(UInt16(bigEndian: boundAddr.sin_port))
        listenFd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setEventHandler { [weak self] in self?.acceptClient(listener: fd) }
        source.resume()
        acceptSource = source
    }

    func stop() {
        lock.lock()
        stopped = true
        let source = acceptSource
        acceptSource = nil
        let listen = listenFd
        listenFd = -1
        let clients = clientFds
        clientFds.removeAll()
        idleFds.removeAll()
        lock.unlock()
        source?.cancel()
        if listen >= 0 { close(listen) }
        for fd in clients {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    func dropClients() {
        lock.lock()
        let clients = clientFds
        clientFds.removeAll()
        idleFds.removeAll()
        lock.unlock()
        for fd in clients {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    /// Record a message without an unsolicited EXISTS, as when an IDLE push is missed.
    func store(_ message: ScriptMessage) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    /// Append a message and tell every connected client, including one already in IDLE.
    func append(_ message: ScriptMessage) {
        lock.lock()
        messages.append(message)
        let count = messages.count
        let fds = clientFds
        lock.unlock()
        let line = Data("* \(count) EXISTS\r\n".utf8)
        for fd in fds { writeAll(fd, line) }
    }

    func replaceMailbox(uidValidity: UInt32, messages: [ScriptMessage]) {
        lock.lock()
        self.uidValidity = uidValidity
        self.messages = messages
        lock.unlock()
    }

    var commandLog: [String] {
        lock.lock()
        defer { lock.unlock() }
        return commandLogStorage
    }

    func waitUntil(
        timeout: Duration = .seconds(8),
        _ predicate: @escaping @Sendable ([String]) -> Bool
    ) async throws {
        try await waitForSignal(
            timeout: timeout, isSatisfied: { predicate(self.commandLog) },
            park: { await self.parkLogWaiter(predicate) }
        )
    }

    private func parkLogWaiter(_ predicate: @escaping @Sendable ([String]) -> Bool) async {
        let gate = SignalGate()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                let ready = predicate(commandLogStorage)
                if !ready { logWaiters.append(gate) }
                lock.unlock()
                gate.register(continuation, ready: ready)
            }
        } onCancel: {
            gate.resume()
            lock.lock()
            logWaiters.removeAll { $0 === gate }
            lock.unlock()
        }
    }

    var acceptedConnectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return acceptedStorage
    }

    var matchedLoginCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loginMatches
    }

    private func acceptClient(listener: Int32) {
        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let fd = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(listener, $0, &addrLen)
            }
        }
        guard fd >= 0 else { return }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        lock.lock()
        if stopped {
            lock.unlock()
            close(fd)
            return
        }
        clientFds.insert(fd)
        acceptedStorage += 1
        lock.unlock()
        DispatchQueue.global().async { [weak self] in
            self?.handle(fd)
        }
    }

    private func handle(_ fd: Int32) {
        defer {
            lock.lock()
            idleFds.remove(fd)
            let owned = clientFds.remove(fd) != nil
            lock.unlock()
            if owned { close(fd) }
        }
        writeAll(fd, Data("* OK ready\r\n".utf8))
        var buffer = Data()
        var authenticated = false
        var selected = false
        var selectedMessageCount = 0
        var idleTag: String?
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
        defer { scratch.deallocate() }
        while true {
            let count = read(fd, scratch, 65536)
            if count <= 0 { return }
            buffer.append(scratch, count: count)
            while let range = buffer.range(of: Data("\r\n".utf8)) {
                let lineData = buffer[..<range.lowerBound]
                buffer.removeSubrange(..<range.upperBound)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                if let tag = idleTag, line.uppercased() == "DONE" {
                    record("DONE")
                    lock.lock()
                    let reject = rejectDone
                    idleFds.remove(fd)
                    lock.unlock()
                    if reject {
                        writeAll(fd, Data("\(tag) BAD DONE failed\r\n".utf8))
                    } else {
                        writeAll(fd, Data("\(tag) OK IDLE terminated\r\n".utf8))
                    }
                    idleTag = nil
                    continue
                }
                let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count >= 2 else {
                    writeAll(fd, Data("* BAD\r\n".utf8))
                    continue
                }
                let tag = parts[0]
                let verb = parts[1].uppercased()
                let args = parts.count > 2 ? parts[2] : ""
                if verb == "LOGIN" {
                    record("\(tag) LOGIN <redacted>")
                } else {
                    record(line)
                }
                if verb == "IDLE" {
                    lock.lock()
                    idleFds.insert(fd)
                    lock.unlock()
                    idleTag = tag
                    writeAll(fd, Data("+ idling\r\n".utf8))
                    continue
                }
                if verb == "NOOP", silenceNoop { continue }
                let response = reply(
                    tag: tag, verb: verb, args: args, selected: &selected,
                    selectedMessageCount: &selectedMessageCount, authenticated: &authenticated)
                writeAll(fd, response)
                if verb == "LOGOUT" { return }
            }
        }
    }

    private func reply(
        tag: String, verb: String, args: String, selected: inout Bool,
        selectedMessageCount: inout Int, authenticated: inout Bool
    ) -> Data {
        switch verb {
        case "CAPABILITY":
            lock.lock()
            let names =
                authenticated
                ? capabilities : capabilities.filter { $0.caseInsensitiveCompare("IDLE") != .orderedSame }
            lock.unlock()
            let listed = names.isEmpty ? "IMAP4rev1" : names.joined(separator: " ")
            return Data("* CAPABILITY \(listed)\r\n\(tag) OK CAPABILITY completed\r\n".utf8)
        case "LOGIN":
            let tokens = quotedTokens(args)
            lock.lock()
            let ok = loginSucceeds && tokens.count >= 2 && tokens[0] == username && tokens[1] == password
            if ok { loginMatches += 1 }
            let advertised = capabilities
            let omitIdle = loginOmitsIdle
            lock.unlock()
            if ok {
                authenticated = true
                if omitIdle {
                    let stale = advertised.filter { $0.caseInsensitiveCompare("IDLE") != .orderedSame }
                    let listed = stale.isEmpty ? "IMAP4rev1" : stale.joined(separator: " ")
                    return Data("\(tag) OK [CAPABILITY \(listed)] LOGIN completed\r\n".utf8)
                }
                let listed = advertised.isEmpty ? "IMAP4rev1" : advertised.joined(separator: " ")
                // Untagged CAPABILITY is what SwiftMail stores from LOGIN. It does not
                // send another CAPABILITY when this list is non-empty.
                return Data("* CAPABILITY \(listed)\r\n\(tag) OK LOGIN completed\r\n".utf8)
            }
            return Data("\(tag) NO [AUTHENTICATIONFAILED] Invalid credentials\r\n".utf8)
        case "EXAMINE":
            selected = true
            return examineData(
                tag: tag, readOnly: true, selectedMessageCount: &selectedMessageCount)
        case "SELECT":
            selected = true
            return examineData(
                tag: tag, readOnly: false, selectedMessageCount: &selectedMessageCount)
        case "UID":
            guard selected else { return Data("\(tag) NO Not selected\r\n".utf8) }
            return uidData(tag: tag, args: args)
        case "FETCH":
            guard selected else { return Data("\(tag) NO Not selected\r\n".utf8) }
            return fetchData(tag: tag, args: args, uidMode: false)
        case "LOGOUT":
            return Data("* BYE\r\n\(tag) OK LOGOUT completed\r\n".utf8)
        case "NOOP":
            let count = lock.withLock { messages.count }
            if selected, count != selectedMessageCount {
                selectedMessageCount = count
                return Data("* \(count) EXISTS\r\n\(tag) OK NOOP completed\r\n".utf8)
            }
            return Data("\(tag) OK NOOP completed\r\n".utf8)
        default:
            return Data("\(tag) BAD \(verb)\r\n".utf8)
        }
    }

    private func examineData(
        tag: String, readOnly: Bool, selectedMessageCount: inout Int
    ) -> Data {
        lock.lock()
        let count = messages.count
        let validity = uidValidity
        let nextUID = (messages.map(\.uid).max() ?? 0) + 1
        let forced = examineReadOnly
        lock.unlock()
        selectedMessageCount = count
        let mode = (readOnly && forced) ? "READ-ONLY" : "READ-WRITE"
        let text = """
            * \(count) EXISTS\r
            * 0 RECENT\r
            * OK [UIDVALIDITY \(validity)] UIDs valid\r
            * OK [UIDNEXT \(nextUID)] Predicted next UID\r
            * FLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft)\r
            * OK [PERMANENTFLAGS ()] Read-only\r
            \(tag) OK [\(mode)] EXAMINE completed\r
            """
        return Data(text.utf8)
    }

    private func uidData(tag: String, args: String) -> Data {
        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard let sub = parts.first?.uppercased() else { return Data("\(tag) BAD\r\n".utf8) }
        let rest = parts.count > 1 ? parts[1] : ""
        if sub == "FETCH" { return fetchData(tag: tag, args: rest, uidMode: true) }
        return Data("\(tag) BAD \(sub)\r\n".utf8)
    }

    private func fetchData(tag: String, args: String, uidMode: Bool) -> Data {
        let seq: String
        let items: String
        if let open = args.firstIndex(of: "("), let close = args.lastIndex(of: ")") {
            seq = String(args[..<open]).trimmingCharacters(in: .whitespaces)
            items = String(args[args.index(after: open)..<close])
        } else {
            return Data("\(tag) BAD FETCH\r\n".utf8)
        }
        lock.lock()
        let snapshot = messages
        let rejectBody = rejectBodyFetch
        lock.unlock()
        let wanted = items.uppercased()
        if rejectBody && (wanted.contains("BODY.PEEK") || wanted.contains("BODY[")) {
            return Data("\(tag) NO FETCH failed\r\n".utf8)
        }
        let matched = match(seq, messages: snapshot, uidMode: uidMode)
        var response = Data()
        for (offset, message) in matched {
            var pieces: [Data] = []
            if wanted.contains("UID") || uidMode {
                pieces.append(Data("UID \(message.uid)".utf8))
            }
            if wanted.contains("ENVELOPE") {
                pieces.append(Data("ENVELOPE \(envelope(message))".utf8))
            }
            if wanted.contains("INTERNALDATE") {
                pieces.append(Data("INTERNALDATE \"\(imapDate(message.internalDate))\"".utf8))
            }
            if wanted.contains("RFC822.SIZE") {
                pieces.append(Data("RFC822.SIZE \(message.body.count)".utf8))
            }
            if wanted.contains("BODYSTRUCTURE") {
                pieces.append(Data("BODYSTRUCTURE \(structure(message))".utf8))
            }
            if wanted.contains("BODY.PEEK") || wanted.contains("BODY[") {
                pieces.append(bodyPiece(message, items: items))
            }
            var row = Data("* \(offset) FETCH (".utf8)
            for (index, piece) in pieces.enumerated() {
                if index > 0 { row.append(Data(" ".utf8)) }
                row.append(piece)
            }
            row.append(Data(")\r\n".utf8))
            response.append(row)
        }
        response.append(Data("\(tag) OK FETCH completed\r\n".utf8))
        return response
    }

    private func match(_ seq: String, messages: [ScriptMessage], uidMode: Bool) -> [(Int, ScriptMessage)] {
        var result: [(Int, ScriptMessage)] = []
        for part in seq.split(separator: ",").map(String.init) {
            let bounds = part.split(separator: ":").map(String.init)
            let start = Int(bounds[0]) ?? 1
            let end: Int
            if bounds.count == 1 {
                end = start
            } else if bounds[1] == "*" {
                end = uidMode ? Int(messages.map(\.uid).max() ?? 0) : messages.count
            } else {
                end = Int(bounds[1]) ?? start
            }
            for (index, message) in messages.enumerated() {
                let value = uidMode ? Int(message.uid) : index + 1
                if value >= start && value <= end {
                    result.append((index + 1, message))
                }
            }
        }
        return result
    }

    private func bodyPiece(_ message: ScriptMessage, items: String) -> Data {
        if let partial = partialRequest(items) {
            let payload = partBody(message, section: partial.section)
            let start = min(partial.offset, payload.count)
            let end = min(start + partial.count, payload.count)
            let slice = payload.subdata(in: start..<end)
            var data = Data("BODY[\(partial.section)]<\(partial.offset)> {\(slice.count)}\r\n".utf8)
            data.append(slice)
            return data
        }
        var data = Data("BODY[1] {\(message.body.count)}\r\n".utf8)
        data.append(message.body)
        return data
    }

    private func partBody(_ message: ScriptMessage, section: String) -> Data {
        if section == "2", let html = message.htmlBody { return html }
        return message.body
    }

    private func partialRequest(_ items: String) -> (section: String, offset: Int, count: Int)? {
        let pattern = #"BODY(?:\.PEEK)?\[([0-9]+(?:\.[0-9]+)*)\]<([0-9]+)\.([0-9]+)>"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: items, range: NSRange(items.startIndex..., in: items)),
            let section = Range(match.range(at: 1), in: items),
            let offset = Range(match.range(at: 2), in: items),
            let count = Range(match.range(at: 3), in: items),
            let offsetValue = Int(items[offset]),
            let countValue = Int(items[count])
        else { return nil }
        return (String(items[section]), offsetValue, countValue)
    }

    private func structure(_ message: ScriptMessage) -> String {
        let plain = singleStructure(
            mime: message.mime, charset: message.charset, encoding: message.transferEncoding,
            octets: message.declaredOctets ?? message.body.count, lines: lineCount(message.body))
        guard let html = message.htmlBody else { return plain }
        let htmlStructure = singleStructure(
            mime: "text/html", charset: "utf-8", encoding: "7BIT",
            octets: html.count, lines: lineCount(html))
        return "(\(plain)\(htmlStructure) \"ALTERNATIVE\")"
    }

    private func singleStructure(
        mime: String, charset: String, encoding: String, octets: Int, lines: Int
    ) -> String {
        let parts = mime.split(separator: "/")
        let type = parts.first.map { $0.uppercased() } ?? "TEXT"
        let subtype = parts.count > 1 ? parts[1].uppercased() : "PLAIN"
        return
            "(\"\(type)\" \"\(subtype)\" (\"CHARSET\" \"\(charset.uppercased())\") NIL NIL \"\(encoding)\" \(octets) \(lines))"
    }

    private func lineCount(_ body: Data) -> Int {
        max(body.filter { $0 == 10 }.count, 1)
    }

    private func envelope(_ message: ScriptMessage) -> String {
        let subject = quote(message.subject)
        let date = quote(message.envelopeDate)
        let from = address(message.from)
        let id = quote("<\(message.uid)@example.test>")
        return "(\(date) \(subject) \(from) \(from) \(from) \(from) NIL NIL NIL \(id))"
    }

    private func address(_ header: String) -> String {
        let name: String
        let email: String
        if let open = header.firstIndex(of: "<"), let close = header.firstIndex(of: ">") {
            name = String(header[..<open]).trimmingCharacters(in: .whitespaces)
            email = String(header[header.index(after: open)..<close])
        } else {
            name = ""
            email = header
        }
        let bits = email.split(separator: "@")
        guard bits.count == 2 else { return "NIL" }
        let nameToken = name.isEmpty ? "NIL" : quote(name)
        return "((\(nameToken) NIL \(quote(String(bits[0]))) \(quote(String(bits[1])))))"
    }

    private func quote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
            of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func imapDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    private func quotedTokens(_ args: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoting = false
        var escaping = false
        for character in args {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" && quoting {
                escaping = true
                continue
            }
            if character == "\"" {
                if quoting {
                    tokens.append(current)
                    current = ""
                }
                quoting.toggle()
                continue
            }
            if quoting { current.append(character) }
        }
        return tokens
    }

    private func record(_ line: String) {
        lock.lock()
        commandLogStorage.append(line)
        let pending = logWaiters
        logWaiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }

    private func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let wrote = write(fd, base + sent, data.count - sent)
                if wrote <= 0 { return }
                sent += wrote
            }
        }
    }
}

struct ScriptServerError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
