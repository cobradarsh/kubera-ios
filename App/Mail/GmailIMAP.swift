// GmailIMAP.swift - Kubera
// Read-only Gmail reader: IMAP over TLS to imap.gmail.com:993 on Network.framework.
// The mailbox is opened with EXAMINE and bodies are fetched with BODY.PEEK, so nothing in Gmail changes
// (no mail is marked as read). The app password goes to the server only: never into errors or logs.

import Foundation
import Network

public enum IMAPError: Error, LocalizedError {
    case connection(String)
    case authenticationFailed
    case protocolError(String)
    case timeout
    case mailboxNotFound

    public var errorDescription: String? {
        switch self {
        case .connection(let why): return "Could not talk to Gmail: \(why)"
        case .authenticationFailed: return "Gmail did not accept the address and app password."
        case .protocolError(let why): return "Unexpected reply from Gmail: \(why)"
        case .timeout: return "Gmail did not answer in time."
        case .mailboxNotFound: return "Could not open Gmail's All Mail folder."
        }
    }
}

/// Set the public timeouts before calling; each call opens and closes its own connection.
public final class GmailIMAPClient: @unchecked Sendable {
    public typealias FetchResult = (messages: [MailMessage], uidValidity: UInt32, highestUID: UInt32)

    public static let host = "imap.gmail.com"
    public static let port: UInt16 = 993
    /// How long a command may go without any reply from the server.
    public var commandTimeout: TimeInterval = 30
    /// How long one verifyLogin() or fetch() may take in all.
    public var overallTimeout: TimeInterval = 300
    /// Bytes fetched per message (BODY.PEEK[]<0.n>); alerts are far smaller.
    public var maxMessageBytes = 200_000
    static let fetchBatchSize = 20

    private let email: String
    private let password: String

    public init(email: String, appPassword: String) {
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = appPassword.filter { !$0.isWhitespace }      // Google shows it in groups of four
    }

    /// Connects, authenticates and logs out.
    public func verifyLogin() async throws {
        _ = try await withSession { (_: IMAPSession) -> Bool in true }
    }

    /// Runs UID SEARCH X-GM-RAW <query> in the mailbox with the \All attribute ("[Gmail]/All Mail"; the name
    /// is localised), opened with EXAMINE, then UID FETCH (UID INTERNALDATE BODY.PEEK[]<0.200000>) in
    /// batches of 20. Only UIDs above `sinceUID` when it is given and `uidValidity` still matches; at most
    /// the newest `limit` messages. `highestUID` is the highest UID the search matched (or `sinceUID`).
    public func fetch(query: String, sinceUID: UInt32?, uidValidity: UInt32?, limit: Int) async throws
        -> (messages: [MailMessage], uidValidity: UInt32, highestUID: UInt32) {
        let batchSize = GmailIMAPClient.fetchBatchSize
        let maxBytes = maxMessageBytes
        return try await withSession { (session: IMAPSession) async throws -> FetchResult in
            let validity = try await session.openAllMail()
            // UIDs saved under another UIDVALIDITY mean nothing now: start again from the query alone.
            let seenUpTo: UInt32? = (uidValidity == nil || uidValidity == validity) ? sinceUID : nil
            var uids = try await session.uidSearch(rawQuery: query, above: seenUpTo)
            if let seenUpTo = seenUpTo { uids = uids.filter { $0 > seenUpTo } }   // "n:*" also returns the last UID
            uids = Array(Set(uids)).sorted()
            let highest = max(uids.last ?? 0, seenUpTo ?? 0)
            let wanted = limit > 0 ? Array(uids.suffix(limit)) : []
            var messages: [MailMessage] = []
            var index = 0
            while index < wanted.count {
                let batch = Array(wanted[index..<min(index + batchSize, wanted.count)])
                messages += try await session.uidFetch(batch, maxBytes: maxBytes)
                index += batchSize
            }
            messages.sort { $0.uid < $1.uid }
            return (messages: messages, uidValidity: validity, highestUID: highest)
        }
    }

    /// X-GM-RAW search for Indian bank, card and UPI alert mail received on or after `since`:
    /// (from a known sender OR an alert-like subject) AND an alert word anywhere.
    public static func defaultAlertQuery(since: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy/MM/dd"
        let senders = [
            "hdfcbank", "icicibank", "sbi", "sbicard", "onlinesbi", "axisbank", "axis", "kotak", "yesbank",
            "idfcfirstbank", "indusind", "aubank", "federalbank", "rblbank", "sc.com", "standardchartered",
            "citi", "citibank", "americanexpress", "aexp", "getonecard", "onecard", "sliceit", "slice",
            "cred.club", "phonepe", "paytm", "amazonpay", "googlepay",
        ]
        let words = [
            "debited", "credited", "spent", "transaction", "\"transaction alert\"", "txn", "UPI",
            "\"payment received\"", "InstaAlert", "InstaAlerts",
        ].joined(separator: " OR ")
        return "after:\(f.string(from: since)) (from:(\(senders.joined(separator: " OR "))) OR subject:(\(words))) (\(words))"
    }

    private func withSession<T>(_ body: @escaping (IMAPSession) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let session = IMAPSession(host: GmailIMAPClient.host, port: GmailIMAPClient.port,
                                  commandTimeout: commandTimeout, overallTimeout: overallTimeout)
        let user = email
        let secret = password
        return try await withTaskCancellationHandler { () async throws -> T in
            defer { session.close() }
            do {
                try await session.connect()
                try await session.login(user: user, password: secret)
                let result = try await body(session)
                await session.logout()
                return result
            } catch let error as IMAPError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw IMAPError.protocolError(session.scrub(String(describing: error)))
            }
        } onCancel: {
            session.abort(with: CancellationError())
        }
    }
}

/// Resumes a continuation once, from whichever side gets there first (callback, abort or timeout).
private final class OneShot<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}

/// One IMAP connection, driven by one task at a time. The lock guards what the network queue, the timer
/// and the cancellation handler share with that task.
final class IMAPSession: @unchecked Sendable {
    enum Part {
        case text(String)
        case literal(Data)
    }

    struct Reply {
        let status: String
        let text: String
        let untagged: [IMAPResponse]
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.cobradarsh.kubera.imap")
    private let commandTimeout: TimeInterval
    private var framer = IMAPResponseFramer()
    private var tagNumber = 0
    private var capabilities: Set<String> = []
    private var loggingOut = false

    private let lock = NSLock()
    private var secrets: [String] = []                 // removed from any server text that goes into an error
    private var abortError: Error?
    private var failPending: ((Error) -> Void)?
    private var timer: DispatchSourceTimer?
    private let overallDeadline: TimeInterval          // ProcessInfo.systemUptime
    private var commandDeadline: TimeInterval?
    private var activeTimeout: TimeInterval

    init(host: String, port: UInt16, commandTimeout: TimeInterval, overallTimeout: TimeInterval) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(commandTimeout.rounded(.up))
        let parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)   // system trust, SNI = host
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 993,
                                  using: parameters)
        self.commandTimeout = commandTimeout
        activeTimeout = commandTimeout
        overallDeadline = ProcessInfo.processInfo.systemUptime + overallTimeout
    }

    // MARK: Session steps

    func connect() async throws {
        startTimer()
        beginCommand(timeout: commandTimeout)
        defer { endCommand() }
        try await waitFor { (shot: OneShot<Void>) in
            self.connection.stateUpdateHandler = { state in
                switch state {
                case .ready: shot.resume(.success(()))
                case .failed(let error): shot.resume(.failure(IMAPError.connection(IMAPSession.describe(error))))
                case .waiting(let error): shot.resume(.failure(IMAPError.connection(IMAPSession.describe(error))))
                case .cancelled: shot.resume(.failure(IMAPError.connection("cancelled")))
                default: break
                }
            }
            self.connection.start(queue: self.queue)
        }
        let greeting = try await readResponse()
        if greeting.status == "BYE" { throw IMAPError.connection("Gmail refused: \(scrub(greeting.text))") }
        guard greeting.kind == .untagged, greeting.status == "OK" || greeting.status == "PREAUTH" else {
            throw IMAPError.protocolError("unexpected greeting")
        }
        if let caps = IMAPParser.capabilities(greeting) { capabilities = caps }
    }

    /// AUTHENTICATE PLAIN with an initial response (SASL-IR), else LOGIN.
    func login(user: String, password: String) async throws {
        let token = Data("\u{0}\(user)\u{0}\(password)".utf8).base64EncodedString()
        lock.lock()
        secrets = [password, token]
        lock.unlock()
        if capabilities.isEmpty {
            _ = try await command([.text("CAPABILITY")], name: "CAPABILITY")
        }
        if capabilities.contains("AUTH=PLAIN") && capabilities.contains("SASL-IR") {
            // A continuation request here would mean the server ignored the initial response: cancel with "*".
            let reply = try await command([.text("AUTHENTICATE PLAIN " + token)], name: "AUTHENTICATE",
                                          onContinuation: { _ in Data("*\r\n".utf8) })
            if reply.status == "OK" { return }
            if reply.status == "NO" { throw IMAPError.authenticationFailed }
            // BAD: the server would not take it after all; LOGIN below.
        }
        if capabilities.contains("LOGINDISABLED") { throw IMAPError.protocolError("password login is disabled") }
        var parts: [Part] = [.text("LOGIN ")]
        parts += astring(user)
        parts.append(.text(" "))
        parts += astring(password)
        let reply = try await command(parts, name: "LOGIN")
        if reply.status == "NO" { throw IMAPError.authenticationFailed }
        guard reply.status == "OK" else { throw IMAPError.protocolError("LOGIN: \(reply.text)") }
    }

    /// EXAMINEs (read-only) the \All mailbox and returns its UIDVALIDITY.
    func openAllMail() async throws -> UInt32 {
        var candidates: [String] = []
        let list = try await command([.text("LIST \"\" \"*\"")], name: "LIST")
        if list.status == "OK",
           let all = list.untagged.compactMap({ IMAPParser.listResult($0) }).first(where: { $0.hasAttribute("\\All") }) {
            candidates.append(all.name)
        }
        for name in ["[Gmail]/All Mail", "[Google Mail]/All Mail", "INBOX"] where !candidates.contains(name) {
            candidates.append(name)
        }
        for name in candidates {
            let reply = try await command([Part.text("EXAMINE ")] + astring(name), name: "EXAMINE")
            guard reply.status == "OK" else { continue }
            guard let validity = reply.untagged.compactMap({ IMAPParser.uidValidity($0) }).first else {
                throw IMAPError.protocolError("EXAMINE without UIDVALIDITY")
            }
            return validity
        }
        throw IMAPError.mailboxNotFound
    }

    func uidSearch(rawQuery: String, above seenUpTo: UInt32?) async throws -> [UInt32] {
        var parts: [Part] = [.text("UID SEARCH ")]
        if IMAPParser.quoted(rawQuery) == nil { parts.append(.text("CHARSET UTF-8 ")) }   // sent as a literal
        if let seenUpTo = seenUpTo {
            guard seenUpTo < UInt32.max else { return [] }
            parts.append(.text("UID \(seenUpTo + 1):* "))
        }
        parts.append(.text("X-GM-RAW "))
        parts += astring(rawQuery)
        let reply = try await command(parts, name: "SEARCH")
        guard reply.status == "OK" else { throw IMAPError.protocolError("SEARCH: \(reply.text)") }
        return reply.untagged.compactMap({ IMAPParser.searchResults($0) }).flatMap { $0 }
    }

    func uidFetch(_ uids: [UInt32], maxBytes: Int) async throws -> [MailMessage] {
        guard !uids.isEmpty else { return [] }
        let set = uids.map { String($0) }.joined(separator: ",")
        let reply = try await command([.text("UID FETCH \(set) (UID INTERNALDATE BODY.PEEK[]<0.\(maxBytes)>)")],
                                      name: "FETCH")
        // NO can mean some messages vanished meanwhile; keep the ones that came.
        guard reply.status != "BAD" else { throw IMAPError.protocolError("FETCH: \(reply.text)") }
        let wanted = Set(uids)
        var seen = Set<UInt32>()
        var messages: [MailMessage] = []
        for response in reply.untagged {
            guard let fetch = IMAPParser.fetchResult(response), let uid = fetch.uid, let body = fetch.body,
                  wanted.contains(uid), !seen.contains(uid) else { continue }
            seen.insert(uid)
            messages.append(MIMEDecoder.decode(body, uid: uid, internalDate: fetch.internalDate))
        }
        return messages
    }

    /// Polite LOGOUT; errors and slowness are ignored.
    func logout() async {
        loggingOut = true
        _ = try? await command([.text("LOGOUT")], name: "LOGOUT", timeout: 5)
    }

    func close() {
        lock.lock()
        let t = timer
        timer = nil
        failPending = nil
        lock.unlock()
        t?.cancel()
        connection.cancel()
    }

    /// Fails whatever is waiting with `error` and closes the connection (cancellation and timeouts).
    func abort(with error: Error) {
        lock.lock()
        if abortError == nil { abortError = error }
        let reason = abortError ?? error
        let fail = failPending
        failPending = nil
        let t = timer
        timer = nil
        lock.unlock()
        t?.cancel()
        fail?(reason)
        connection.cancel()
    }

    /// Server text with the password (or its SASL token) blanked out, shortened.
    func scrub(_ text: String) -> String {
        lock.lock()
        let hidden = secrets
        lock.unlock()
        var t = text
        for s in hidden where !s.isEmpty { t = t.replacingOccurrences(of: s, with: "***") }
        return String(t.prefix(200))
    }

    // MARK: Commands

    private func command(_ parts: [Part], name: String, timeout: TimeInterval? = nil,
                         onContinuation: ((IMAPResponse) -> Data?)? = nil) async throws -> Reply {
        try checkAborted()
        tagNumber += 1
        let tag = "K\(tagNumber)"
        var untagged: [IMAPResponse] = []
        var line = tag + " "
        beginCommand(timeout: timeout ?? commandTimeout)
        defer { endCommand() }
        for part in parts {
            switch part {
            case .text(let s):
                line += s
            case .literal(let bytes):
                // Synchronising literal: announce it, wait for "+", then send the bytes.
                line += "{\(bytes.count)}\r\n"
                try await send(Data(line.utf8))
                line = ""
                waiting: while true {
                    let r = try await readResponse()
                    if r.kind == .continuation { break waiting }
                    if case .tagged(let t) = r.kind, t == tag {
                        return Reply(status: r.status ?? "BAD", text: scrub(r.text), untagged: untagged)
                    }
                    try note(r, into: &untagged)
                }
                try await send(bytes)
            }
        }
        line += "\r\n"
        try await send(Data(line.utf8))
        while true {
            let r = try await readResponse()
            switch r.kind {
            case .tagged(let t) where t == tag:
                return Reply(status: r.status ?? "BAD", text: scrub(r.text), untagged: untagged)
            case .tagged:
                continue                                       // reply to an earlier command; not ours
            case .continuation:
                guard let answer = onContinuation?(r) else {
                    throw IMAPError.protocolError("\(name): unexpected continuation request")
                }
                try await send(answer)
            case .untagged:
                try note(r, into: &untagged)
            }
        }
    }

    private func note(_ r: IMAPResponse, into list: inout [IMAPResponse]) throws {
        if r.status == "BYE" && !loggingOut { throw IMAPError.connection("Gmail closed the session: \(scrub(r.text))") }
        if let caps = IMAPParser.capabilities(r) { capabilities = caps }
        list.append(r)
    }

    private func astring(_ s: String) -> [Part] {
        if let q = IMAPParser.quoted(s) { return [.text(q)] }
        return [.literal(Data(s.utf8))]
    }

    // MARK: I/O

    private func readResponse() async throws -> IMAPResponse {
        while true {
            let next: [UInt8]?
            do {
                next = try framer.next()
            } catch {
                throw IMAPError.protocolError(String(describing: error))
            }
            if let bytes = next {
                do {
                    return try IMAPParser.parseResponse(bytes)
                } catch {
                    throw IMAPError.protocolError(String(describing: error))
                }
            }
            let chunk = try await receive()
            framer.append(chunk)
        }
    }

    private func receive() async throws -> Data {
        let data = try await waitFor { (shot: OneShot<Data>) in
            self.connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { content, _, isComplete, error in
                if let content = content, !content.isEmpty {
                    shot.resume(.success(content))
                } else if let error = error {
                    shot.resume(.failure(IMAPError.connection(IMAPSession.describe(error))))
                } else if isComplete {
                    shot.resume(.failure(IMAPError.connection("Gmail closed the connection")))
                } else {
                    shot.resume(.success(Data()))
                }
            }
        }
        touch()
        return data
    }

    private func send(_ data: Data) async throws {
        try await waitFor { (shot: OneShot<Void>) in
            self.connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    shot.resume(.failure(IMAPError.connection(IMAPSession.describe(error))))
                } else {
                    shot.resume(.success(()))
                }
            })
        }
    }

    /// Waits for a callback. abort(with:) fails the wait at once; a callback that comes later is ignored.
    private func waitFor<T>(_ start: (OneShot<T>) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let shot = OneShot(continuation)
            self.lock.lock()
            if let error = self.abortError {
                self.lock.unlock()
                shot.resume(.failure(error))
                return
            }
            self.failPending = { shot.resume(.failure($0)) }
            self.lock.unlock()
            start(shot)
        }
    }

    private func checkAborted() throws {
        lock.lock()
        let error = abortError
        lock.unlock()
        if let error = error { throw error }
        if Task.isCancelled { throw CancellationError() }
    }

    private static func describe(_ error: NWError) -> String {
        String(describing: error)
    }

    // MARK: Timeouts

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.checkDeadlines() }
        lock.lock()
        timer = t
        lock.unlock()
        t.resume()
    }

    private func checkDeadlines() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let expired = now > overallDeadline || (commandDeadline.map { now > $0 } ?? false)
        lock.unlock()
        if expired { abort(with: IMAPError.timeout) }
    }

    /// The command deadline restarts whenever bytes arrive, so a large FETCH that keeps coming is not cut off;
    /// the overall deadline bounds the whole session.
    private func beginCommand(timeout: TimeInterval) {
        lock.lock()
        activeTimeout = timeout
        commandDeadline = ProcessInfo.processInfo.systemUptime + timeout
        lock.unlock()
    }

    private func touch() {
        lock.lock()
        if commandDeadline != nil { commandDeadline = ProcessInfo.processInfo.systemUptime + activeTimeout }
        lock.unlock()
    }

    private func endCommand() {
        lock.lock()
        commandDeadline = nil
        lock.unlock()
    }
}
