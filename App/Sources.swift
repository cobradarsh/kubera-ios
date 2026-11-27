import Foundation
import SQLite3

/// Reads the Messages database directly (TrollStore entitlements: no sandbox + Messages storage). Read-only.
enum SMSReader {
    static let path = "/var/mobile/Library/SMS/sms.db"

    struct Result {
        var messages: [RawMessage] = []
        var maxRowID: Int64
        var scanned = 0
        var error: String?
    }

    static func read(after rowID: Int64, limit: Int = 50_000) -> Result {
        var result = Result(maxRowID: rowID)
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let db else {
            result.error = "Cannot open the Messages database (\(rc)): " + (db.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle")
            if let db { sqlite3_close(db) }
            return result
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        sqlite3_exec(db, "PRAGMA query_only = 1", nil, nil, nil)

        let sql = """
        SELECT m.ROWID, m.date, m.text, m.attributedBody, h.id, m.service
        FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE m.ROWID > ? AND m.is_from_me = 0
        ORDER BY m.ROWID ASC LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            result.error = "Query failed: " + String(cString: sqlite3_errmsg(db))
            return result
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, rowID)
        sqlite3_bind_int64(stmt, 2, Int64(limit))

        while sqlite3_step(stmt) == SQLITE_ROW {
            result.scanned += 1
            let rid = sqlite3_column_int64(stmt, 0)
            result.maxRowID = max(result.maxRowID, rid)
            let handle = text(stmt, 4) ?? ""
            let service = text(stmt, 5) ?? ""
            // Business senders only: never people (phone numbers, e-mail addresses, iMessage).
            if handle.isEmpty || handle.contains("@") || service == "iMessage" { continue }
            if MessageParser.senderInfo(handle).isPersonalNumber { continue }
            var body = text(stmt, 2) ?? ""
            if body.isEmpty { body = decodeAttributedBody(blob(stmt, 3)) ?? "" }
            if body.isEmpty { continue }
            let date = appleDate(sqlite3_column_int64(stmt, 1))
            result.messages.append(RawMessage(id: "sms:\(rid)", date: date, sender: handle, text: body, source: .sms))
        }
        return result
    }

    /// Message times are nanoseconds (seconds before iOS 11) since 2001-01-01.
    static func appleDate(_ v: Int64) -> Date {
        let s = v > 100_000_000_000 ? Double(v) / 1e9 : Double(v)
        return Date(timeIntervalSinceReferenceDate: s)
    }

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(s, i) else { return nil }
        return String(cString: c)
    }

    private static func blob(_ s: OpaquePointer, _ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(s, i) else { return nil }
        let n = Int(sqlite3_column_bytes(s, i))
        return n > 0 ? Data(bytes: p, count: n) : nil
    }

    /// The text inside an `attributedBody` typedstream (used when `text` is empty).
    static func decodeAttributedBody(_ data: Data?) -> String? {
        guard let d = data, let r = d.range(of: Data("NSString".utf8)) else { return nil }
        var i = r.upperBound + 5
        guard i < d.count else { return nil }
        var len = Int(d[i])
        i += 1
        if len == 0x81 {
            guard i + 2 <= d.count else { return nil }
            len = Int(d[i]) | (Int(d[i + 1]) << 8)
            i += 2
        } else if len == 0x82 {
            guard i + 4 <= d.count else { return nil }
            len = Int(d[i]) | (Int(d[i + 1]) << 8) | (Int(d[i + 2]) << 16) | (Int(d[i + 3]) << 24)
            i += 4
        }
        guard len > 0, i + len <= d.count else { return nil }
        return String(data: d.subdata(in: i..<(i + len)), encoding: .utf8)
    }

    static func probe() -> String {
        let fm = FileManager.default
        let readable = fm.isReadableFile(atPath: path)
        let r = read(after: Int64.max - 1, limit: 1)
        return "sms.db readable=\(readable) open=\(r.error ?? "ok")"
    }
}

/// Lines the Kubera Listener tweak appended to `/var/mobile/Library/Kubera/inbox.jsonl`.
enum NotificationInbox {
    struct Line: Decodable {
        var v: Int?
        var id: String?
        var app: String?
        var t: Double?
        var title: String?
        var subtitle: String?
        var body: String?
    }

    struct Result {
        var messages: [RawMessage] = []
        var offsets: [String: UInt64]
        var lines = 0
    }

    static var files: [URL] {
        [Paths.shared.appendingPathComponent("inbox.1.jsonl"), Paths.shared.appendingPathComponent("inbox.jsonl")]
    }

    /// Offsets are kept per file identity (inode), so a rotated file is finished before the new one starts.
    static func read(offsets: [String: UInt64]) -> Result {
        var result = Result(offsets: [:])
        let fm = FileManager.default
        for url in files {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value,
                  let size = (attrs[.size] as? NSNumber)?.uint64Value else { continue }
            let key = String(inode)
            var start = offsets[key] ?? 0
            if start > size { start = 0 }
            result.offsets[key] = size
            guard size > start, let h = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? h.close() }
            try? h.seek(toOffset: start)
            guard let data = try? h.readToEnd() else { continue }
            // Only whole lines; a half-written last line is read next time.
            var consumed = 0
            for chunk in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).dropLast() {
                consumed += chunk.count + 1
                result.lines += 1
                guard let line = try? JSONDecoder().decode(Line.self, from: Data(chunk)) else { continue }
                let text = [line.title, line.subtitle, line.body].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                guard !text.isEmpty else { continue }
                let app = line.app ?? "app"
                // The tweak writes "" when a notification has no identifier; the text hash keeps those apart.
                let nid = (line.id ?? "").isEmpty ? nil : line.id
                let id = nid.map { "ntf:\(app):\($0):\(text.stableHash)" } ?? "ntf:\(app):\(Int(line.t ?? 0)):\(text.stableHash)"
                result.messages.append(RawMessage(id: id, date: Date(timeIntervalSince1970: line.t ?? Date().timeIntervalSince1970),
                                                  sender: app, text: text, source: .notification))
            }
            result.offsets[key] = start + UInt64(consumed)
        }
        return result
    }

    /// Apps the tweak listens to (written for it as listener.json).
    static let defaultApps = [
        "com.google.paisa", "in.org.npci.ios.upiapp", "com.phonepe.PhonePeApp", "net.one97.paytm", "com.amazon.AmazonIN",
        "com.dreamplug.cred", "com.google.Gmail", "com.apple.mobilemail", "com.dhan.live", "com.zerodha.kite3", "com.kotak.neo",
        "com.BhartiMobile.myairtel", "com.jio.myjio", "com.snapwork.hdfc", "com.hdfcbank.payzapp", "com.icicibank.imobile",
        "com.sbi.lotusintouch", "com.axis.mobile", "com.kotak.mahindra.kotakbank", "com.upstox.pro", "com.nextbillion.groww",
    ]

    static func writeConfig(enabled: Bool, apps: [String]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.shared, withIntermediateDirectories: true)
        let obj: [String: Any] = ["enabled": enabled, "apps": apps]
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: Paths.shared.appendingPathComponent("listener.json"), options: .atomic)
        }
        DarwinNote.post(DarwinNote.listenerConfig)
    }

    /// Whether the tweak is installed and has run (its log exists).
    static var tweakSeen: Bool {
        FileManager.default.fileExists(atPath: "/var/mobile/Library/Logs/KuberaListener.log")
    }
}
