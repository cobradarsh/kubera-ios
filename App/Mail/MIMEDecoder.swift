// MIMEDecoder.swift - Kubera
// Pure (Foundation only): turns the raw bytes of a mail message into a MailMessage with plain text.
// RFC 822/5322 headers (folding), RFC 2047 encoded words, RFC 2045/2046 multipart and transfer encodings,
// charsets, and HTML to text. Messages may be cut off (the reader fetches only the first 200 kB), so every
// step is lenient about missing ends.

import Foundation

public struct MailMessage: Codable, Equatable, Sendable {
    public let uid: UInt32
    /// INTERNALDATE from the server, else the Date header.
    public let date: Date?
    /// "Display Name <address>", or just the address.
    public let from: String
    public let subject: String
    /// Body as plain text: text/plain when the message has it, else its HTML converted to text.
    public let text: String

    public init(uid: UInt32, date: Date?, from: String, subject: String, text: String) {
        self.uid = uid
        self.date = date
        self.from = from
        self.subject = subject
        self.text = text
    }
}

public enum MIMEDecoder {
    typealias Header = (name: String, value: String)     // name lower-cased, value unfolded, not decoded

    public static func decode(_ raw: Data, uid: UInt32, internalDate: Date?) -> MailMessage {
        let (headerBytes, body) = splitHeaderAndBody([UInt8](raw))
        let headers = parseHeaders(headerBytes)
        var plain: [String] = []
        var html: [String] = []
        collectText(headers: headers, body: body, depth: 0, plain: &plain, html: &html)

        let plainText = plain.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let htmlText = html.filter { !$0.isEmpty }.joined(separator: "\n")
        // Prefer text/plain, unless it is a placeholder ("view this mail in a browser") without any digits
        // while the HTML part has them: alerts always carry an amount.
        var text = plainText
        if text.isEmpty || (!containsDigit(text) && containsDigit(htmlText)) { text = htmlText }

        let date = internalDate ?? field(headers, "date").flatMap(parseHeaderDate)
        return MailMessage(uid: uid, date: date,
                           from: formatAddress(field(headers, "from") ?? ""),
                           subject: collapseSpaces(decodeEncodedWords(field(headers, "subject") ?? "")),
                           text: text)
    }

    // MARK: - Headers

    static func field(_ headers: [Header], _ name: String) -> String? {
        headers.first(where: { $0.name == name })?.value
    }

    /// Splits at the first empty line (CRLF CRLF, or LF LF). Without one, everything is header.
    static func splitHeaderAndBody(_ b: [UInt8]) -> (header: [UInt8], body: [UInt8]) {
        var lineStart = 0
        var i = 0
        while i < b.count {
            if b[i] == 0x0A {
                let length = i - lineStart
                if length == 0 || (length == 1 && b[lineStart] == 0x0D) {
                    return (Array(b[0..<lineStart]), Array(b[(i + 1)...]))
                }
                lineStart = i + 1
            }
            i += 1
        }
        return (b, [])
    }

    /// Header fields in order, unfolded (a line starting with space or tab continues the previous one).
    static func parseHeaders(_ h: [UInt8]) -> [Header] {
        var fields: [[UInt8]] = []
        for line in lines(h) {
            if let first = line.first, first == 0x20 || first == 0x09, !fields.isEmpty {
                fields[fields.count - 1].append(contentsOf: line)
            } else if !line.isEmpty {
                fields.append(line)
            }
        }
        var headers: [Header] = []
        for f in fields {
            guard let colon = f.firstIndex(of: 0x3A) else { continue }
            let name = String(decoding: f[..<colon], as: UTF8.self).trimmingCharacters(in: .whitespaces).lowercased()
            let value = decodeText(Array(f[(colon + 1)...]), charset: nil).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { headers.append((name: name, value: value)) }
        }
        return headers
    }

    /// Lines split at LF, without the CR before it.
    static func lines(_ b: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var start = 0
        var i = 0
        while i <= b.count {
            if i == b.count || b[i] == 0x0A {
                var end = i
                if end > start, b[end - 1] == 0x0D { end -= 1 }
                if i < b.count || start < b.count { out.append(Array(b[start..<end])) }
                start = i + 1
            }
            i += 1
        }
        return out
    }

    /// A structured value such as `text/plain; charset="utf-8"`: the main value (lower-cased) and its
    /// parameters (names lower-cased, values unquoted; RFC 2231 `name*=utf-8''..` and `name*0=` joined).
    static func parseParameters(_ value: String?) -> (value: String, params: [String: String]) {
        guard let value = value else { return ("", [:]) }
        var segments: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for ch in value {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" && inQuotes { current.append(ch); escaped = true; continue }
            if ch == "\"" { inQuotes.toggle() }
            if ch == ";" && !inQuotes { segments.append(current); current = ""; continue }
            current.append(ch)
        }
        segments.append(current)
        let main = segments[0].trimmingCharacters(in: .whitespaces).lowercased()
        var params: [String: String] = [:]
        for segment in segments.dropFirst() {
            guard let eq = segment.firstIndex(of: "=") else { continue }
            var name = segment[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var v = segment[segment.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") {
                v = String(v.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
            if let star = name.firstIndex(of: "*") {
                if name.hasSuffix("*") { v = decodeRFC2231(v) }
                name = String(name[..<star])
                params[name, default: ""] += v
            } else if params[name] == nil {
                params[name] = v
            }
        }
        return (main, params)
    }

    /// `utf-8'en'%E2%82%B9` (first part) or `%20more` (later parts).
    private static func decodeRFC2231(_ v: String) -> String {
        var charset: String?
        var payload = Substring(v)
        let pieces = v.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        if pieces.count == 3 { charset = String(pieces[0]); payload = pieces[2] }
        var bytes: [UInt8] = []
        let utf8 = Array(payload.utf8)
        var i = 0
        while i < utf8.count {
            if utf8[i] == 0x25, i + 2 < utf8.count, let h = hexValue(utf8[i + 1]), let l = hexValue(utf8[i + 2]) {
                bytes.append(h << 4 | l)
                i += 3
            } else {
                bytes.append(utf8[i])
                i += 1
            }
        }
        return decodeText(bytes, charset: charset?.isEmpty == false ? charset : "utf-8")
    }

    /// RFC 2047: =?charset?B?...?= and =?charset?Q?...?=. Whitespace between adjacent encoded words is
    /// dropped, and adjacent words in one charset are decoded together (senders split characters across them).
    static func decodeEncodedWords(_ s: String) -> String {
        guard s.contains("=?"), let re = encodedWordRegex else { return s }
        let ns = s as NSString
        let matches = re.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return s }
        var out = ""
        var cursor = 0
        var pendingBytes: [UInt8] = []
        var pendingCharset: String?
        func flush() {
            if let charset = pendingCharset { out += decodeText(pendingBytes, charset: charset) }
            pendingBytes = []
            pendingCharset = nil
        }
        for m in matches {
            let gap = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let onlySpace = gap.unicodeScalars.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" }
            if pendingCharset == nil || !onlySpace {
                flush()
                out += gap
            }
            let charset = normalizedCharset(ns.substring(with: m.range(at: 1))) ?? "us-ascii"
            let payload = Array(ns.substring(with: m.range(at: 3)).utf8)
            let bytes = ns.substring(with: m.range(at: 2)).uppercased() == "B"
                ? decodeBase64(payload) : decodeQEncoding(payload)
            if let pending = pendingCharset, pending != charset { flush() }
            pendingCharset = charset
            pendingBytes += bytes
            cursor = m.range.location + m.range.length
        }
        flush()
        out += ns.substring(from: cursor)
        return out
    }

    private static let encodedWordRegex = try? NSRegularExpression(pattern: "=\\?([^?\\s]+)\\?([BbQq])\\?([^?]*)\\?=")

    private static func decodeQEncoding(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < b.count {
            let c = b[i]
            if c == 0x5F {                                                   // _ is a space
                out.append(0x20)
            } else if c == 0x3D, i + 2 < b.count, let h = hexValue(b[i + 1]), let l = hexValue(b[i + 2]) {
                out.append(h << 4 | l)
                i += 2
            } else {
                out.append(c)
            }
            i += 1
        }
        return out
    }

    /// "Display Name <address>" with quotes and encoded words removed; just the address when there is no name.
    static func formatAddress(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard let lt = value.lastIndex(of: "<"), let gt = value.lastIndex(of: ">"), lt < gt else {
            return collapseSpaces(decodeEncodedWords(value))
        }
        let address = value[value.index(after: lt)..<gt].trimmingCharacters(in: .whitespaces)
        var name = value[..<lt].trimmingCharacters(in: .whitespaces)
        if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") {
            name = String(name.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        name = collapseSpaces(decodeEncodedWords(name))
        return name.isEmpty ? address : "\(name) <\(address)>"
    }

    private static let headerDateFormatters: [DateFormatter] = {
        let formats = ["d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm:ss zzz", "d MMM yy HH:mm:ss Z"]
        return formats.map { (format: String) -> DateFormatter in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = Calendar(identifier: .gregorian)
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = format
            return f
        }
    }()

    /// RFC 5322 date such as "Thu, 5 Nov 2026 10:15:30 +0530 (IST)".
    static func parseHeaderDate(_ raw: String) -> Date? {
        var s = raw
        if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]) }
        if let comma = s.firstIndex(of: ",") { s = String(s[s.index(after: comma)...]) }
        s = collapseSpaces(s)
        for f in headerDateFormatters {
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    // MARK: - Body parts

    static func collectText(headers: [Header], body: [UInt8], depth: Int, plain: inout [String], html: inout [String]) {
        let contentType = parseParameters(field(headers, "content-type"))
        let params = contentType.params
        var type = contentType.value
        if type.isEmpty || !type.contains("/") { type = "text/plain" }
        if type.hasPrefix("multipart/") {
            guard depth < 12, let boundary = params["boundary"] ?? guessBoundary(body), !boundary.isEmpty else { return }
            for part in splitMultipart(body, boundary: boundary) {
                let (h, b) = splitHeaderAndBody(part)
                collectText(headers: parseHeaders(h), body: b, depth: depth + 1, plain: &plain, html: &html)
            }
            return
        }
        guard type == "text/plain" || type == "text/html" else { return }
        if parseParameters(field(headers, "content-disposition")).value == "attachment" { return }

        let bytes = decodeTransferEncoding(body, field(headers, "content-transfer-encoding"))
        let text = decodeText(bytes, charset: params["charset"])
        if type == "text/html" || looksLikeHTML(text) {
            html.append(htmlToText(text))
        } else {
            var textLines = splitLines(text)
            if params["format"]?.lowercased() == "flowed" {
                textLines = unflow(textLines, deleteSpace: params["delsp"]?.lowercased() == "yes")
            }
            plain.append(tidy(textLines, keepBlankLines: true))
        }
    }

    static func decodeTransferEncoding(_ body: [UInt8], _ header: String?) -> [UInt8] {
        let name = (header ?? "").split(whereSeparator: { $0 == " " || $0 == ";" || $0 == "(" })
            .first.map { $0.lowercased() } ?? ""
        switch name {
        case "base64": return decodeBase64(body)
        case "quoted-printable": return decodeQuotedPrintable(body)
        default: return body                                                 // 7bit, 8bit, binary
        }
    }

    /// Body parts between "--boundary" lines; the line break before a delimiter belongs to it. Without the
    /// closing "--boundary--" (a cut-off message) the last part runs to the end.
    static func splitMultipart(_ body: [UInt8], boundary: String) -> [[UInt8]] {
        let delimiter = Array(("--" + boundary).utf8)
        var parts: [[UInt8]] = []
        var partStart: Int?
        var lineStart = 0
        while lineStart < body.count {
            var lineEnd = lineStart
            while lineEnd < body.count, body[lineEnd] != 0x0A { lineEnd += 1 }
            let next = lineEnd < body.count ? lineEnd + 1 : body.count
            var contentEnd = lineEnd
            if contentEnd > lineStart, body[contentEnd - 1] == 0x0D { contentEnd -= 1 }
            if let closing = delimiterLine(body, lineStart, contentEnd, delimiter) {
                if let s = partStart {
                    var e = lineStart
                    if e > s, body[e - 1] == 0x0A { e -= 1 }
                    if e > s, body[e - 1] == 0x0D { e -= 1 }
                    parts.append(Array(body[s..<e]))
                }
                if closing { return parts }
                partStart = next
            }
            lineStart = next
        }
        if let s = partStart, s < body.count { parts.append(Array(body[s...])) }
        return parts
    }

    /// nil when the line is not a delimiter; true for the closing one. Only whitespace may follow, so a
    /// boundary that is a prefix of a nested one does not match.
    private static func delimiterLine(_ b: [UInt8], _ start: Int, _ end: Int, _ delimiter: [UInt8]) -> Bool? {
        guard end - start >= delimiter.count else { return nil }
        for k in 0..<delimiter.count where b[start + k] != delimiter[k] { return nil }
        var i = start + delimiter.count
        var closing = false
        if i + 2 <= end, b[i] == 0x2D, b[i + 1] == 0x2D { closing = true; i += 2 }
        while i < end {
            if b[i] != 0x20 && b[i] != 0x09 { return nil }
            i += 1
        }
        return closing
    }

    /// For a multipart without a boundary parameter: the first line that looks like a delimiter.
    private static func guessBoundary(_ body: [UInt8]) -> String? {
        for line in lines(body) where line.count > 2 && line[0] == 0x2D && line[1] == 0x2D {
            let b = String(decoding: line.dropFirst(2), as: UTF8.self).trimmingCharacters(in: .whitespaces)
            return b.hasSuffix("--") ? String(b.dropLast(2)) : b
        }
        return nil
    }

    private static func looksLikeHTML(_ s: String) -> Bool {
        let head = s.drop(while: { $0.isWhitespace }).prefix(300).lowercased()
        guard head.hasPrefix("<") else { return false }
        return head.hasPrefix("<!doctype html") || head.hasPrefix("<html") || head.hasPrefix("<body")
            || head.hasPrefix("<table") || head.hasPrefix("<div") || head.hasPrefix("<p>") || head.contains("<br")
    }

    // MARK: - Transfer encodings and charsets

    /// Lenient base64: skips line breaks and junk, accepts missing padding and a cut-off last group.
    static func decodeBase64(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count * 3 / 4)
        var acc: UInt32 = 0
        var n = 0
        for c in input {
            let v: UInt32
            switch c {
            case 0x41...0x5A: v = UInt32(c) - 0x41                          // A-Z
            case 0x61...0x7A: v = UInt32(c) - 0x61 + 26                     // a-z
            case 0x30...0x39: v = UInt32(c) - 0x30 + 52                     // 0-9
            case 0x2B, 0x2D: v = 62                                          // + (- in base64url)
            case 0x2F, 0x5F: v = 63                                          // / (_ in base64url)
            case 0x3D:                                                       // = ends a group
                if n == 2 { out.append(UInt8(truncatingIfNeeded: acc >> 4)) }
                if n == 3 { out.append(UInt8(truncatingIfNeeded: acc >> 10)); out.append(UInt8(truncatingIfNeeded: acc >> 2)) }
                acc = 0
                n = 0
                continue
            default: continue
            }
            acc = (acc << 6) | v
            n += 1
            if n == 4 {
                out.append(UInt8(truncatingIfNeeded: acc >> 16))
                out.append(UInt8(truncatingIfNeeded: acc >> 8))
                out.append(UInt8(truncatingIfNeeded: acc))
                acc = 0
                n = 0
            }
        }
        if n == 2 { out.append(UInt8(truncatingIfNeeded: acc >> 4)) }
        if n == 3 { out.append(UInt8(truncatingIfNeeded: acc >> 10)); out.append(UInt8(truncatingIfNeeded: acc >> 2)) }
        return out
    }

    /// Quoted-printable: "=XX" bytes, "=" before a line end (optionally after spaces) is a soft line break.
    static func decodeQuotedPrintable(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            let c = b[i]
            guard c == 0x3D else { out.append(c); i += 1; continue }
            var j = i + 1
            while j < b.count, b[j] == 0x20 || b[j] == 0x09 { j += 1 }
            if j == b.count { break }                                        // "=" at the cut-off end
            if b[j] == 0x0D || b[j] == 0x0A {                                // soft line break
                if b[j] == 0x0D { j += 1 }
                if j < b.count, b[j] == 0x0A { j += 1 }
                i = j
                continue
            }
            if i + 2 < b.count, let h = hexValue(b[i + 1]), let l = hexValue(b[i + 2]) {
                out.append(h << 4 | l)
                i += 3
            } else {
                out.append(c)                                                // a stray "=" stays
                i += 1
            }
        }
        return out
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x41 + 10
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
    }

    /// Lower-cased charset name without quotes or an RFC 2231 language suffix ("utf-8*en").
    static func normalizedCharset(_ name: String?) -> String? {
        guard var n = name?.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'")).lowercased(), !n.isEmpty else {
            return nil
        }
        if let star = n.firstIndex(of: "*") { n = String(n[..<star]) }
        return n.isEmpty ? nil : n
    }

    static func encoding(forCharset name: String) -> String.Encoding? {
        switch name {
        case "utf-8", "utf8", "unicode-1-1-utf-8": return .utf8
        case "us-ascii", "ascii", "ansi_x3.4-1968", "iso646-us": return .ascii
        // Senders that say ISO-8859-1 nearly always mean windows-1252 (as browsers assume too).
        case "iso-8859-1", "iso8859-1", "iso_8859-1", "latin1", "latin-1", "l1",
             "windows-1252", "cp1252", "x-cp1252", "cp-1252": return .windowsCP1252
        case "utf-16": return .utf16
        case "utf-16le": return .utf16LittleEndian
        case "utf-16be": return .utf16BigEndian
        default:
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf == 0xFFFF_FFFF { return nil }                               // kCFStringEncodingInvalidId
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
    }

    /// Bytes to text in the declared charset, falling back so that nothing is lost: strict UTF-8, then UTF-8
    /// with a few broken sequences (a cut-off message), then windows-1252, then ISO-8859-1 (never fails).
    static func decodeText(_ bytes: [UInt8], charset: String?) -> String {
        let name = normalizedCharset(charset)
        let declared = name.flatMap { encoding(forCharset: $0) }
        if let n = name, let enc = declared, n.hasPrefix("utf-16") || n.hasPrefix("utf-32") || n.hasPrefix("ucs") {
            return String(bytes: bytes, encoding: enc) ?? String(decoding: bytes, as: UTF8.self)
        }
        var high = 0
        for b in bytes where b >= 0x80 { high += 1 }
        if high == 0 { return String(decoding: bytes, as: UTF8.self) }
        if let enc = declared, enc != .utf8, enc != .ascii, let s = String(bytes: bytes, encoding: enc) { return s }
        if let s = String(bytes: bytes, encoding: .utf8) { return s }
        // UTF-8 text cut off inside its last character: drop that character. Only when the rest has other
        // UTF-8 characters, so a single trailing ISO-8859-1 letter is not mistaken for one.
        let trimmed = trimmingPartialUTF8(bytes)
        if trimmed.count < bytes.count, trimmed.contains(where: { $0 >= 0x80 }),
           let s = String(bytes: trimmed, encoding: .utf8) {
            return s
        }
        let lossy = String(decoding: bytes, as: UTF8.self)
        var bad = 0
        for u in lossy.unicodeScalars where u == "\u{FFFD}" { bad += 1 }
        let mostlyUTF8 = declared == .utf8 ? bad * 4 <= high : bad * 20 <= high
        if mostlyUTF8 { return lossy }
        return String(bytes: bytes, encoding: .windowsCP1252) ?? String(bytes: bytes, encoding: .isoLatin1) ?? lossy
    }

    /// `b` without an incomplete UTF-8 sequence at its end.
    private static func trimmingPartialUTF8(_ b: [UInt8]) -> ArraySlice<UInt8> {
        var i = b.count - 1
        var continuationBytes = 0
        while i >= 0, continuationBytes < 3, b[i] & 0xC0 == 0x80 {
            continuationBytes += 1
            i -= 1
        }
        guard i >= 0 else { return b[...] }
        let lead = b[i]
        let needed: Int
        if lead & 0xE0 == 0xC0 {
            needed = 1
        } else if lead & 0xF0 == 0xE0 {
            needed = 2
        } else if lead & 0xF8 == 0xF0 {
            needed = 3
        } else {
            return b[...]
        }
        return continuationBytes < needed ? b[..<i] : b[...]
    }

    // MARK: - HTML to text

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static let blockTags = "p|div|tr|li|h[1-6]|table|ul|ol|blockquote|center|dd|dt|section|article|header|footer"

    /// Applied in order; source line breaks are plain whitespace in HTML, so they go first.
    private static let htmlRules: [(NSRegularExpression?, String)] = [
        (regex("[\\r\\n\\t\\f]+"), " "),
        (regex("<!--.*?-->"), ""),
        (regex("<(head|style|script|title|noscript)\\b[^>]*>.*?</\\1\\s*>"), ""),
        (regex("<br\\b[^>]*>"), "\n"),
        (regex("</(" + blockTags + ")\\s*>"), "\n"),
        (regex("<(" + blockTags + "|hr)\\b[^>]*>"), "\n"),
        (regex("</t[dh]\\s*>"), " "),
        (regex("<(?:/?[a-z][^>]*|![^>]*|\\?[^>]*)>"), ""),
    ]

    static func htmlToText(_ html: String) -> String {
        var s = html
        for (re, template) in htmlRules {
            guard let re = re else { continue }
            s = re.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length),
                                            withTemplate: template)
        }
        return tidy(splitLines(decodeEntities(s)), keepBlankLines: false)
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ensp": " ", "emsp": " ", "thinsp": " ", "zwnj": "", "zwj": "", "lrm": "", "rlm": "", "shy": "",
        "ndash": "\u{2013}", "mdash": "\u{2014}", "minus": "\u{2212}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "sbquo": "\u{201A}", "ldquo": "\u{201C}", "rdquo": "\u{201D}", "bdquo": "\u{201E}", "bull": "\u{2022}",
        "middot": "\u{00B7}", "hellip": "\u{2026}", "laquo": "\u{00AB}", "raquo": "\u{00BB}", "copy": "\u{00A9}",
        "reg": "\u{00AE}", "trade": "\u{2122}", "deg": "\u{00B0}", "plusmn": "\u{00B1}", "times": "\u{00D7}",
        "divide": "\u{00F7}", "cent": "\u{00A2}", "pound": "\u{00A3}", "yen": "\u{00A5}", "euro": "\u{20AC}",
        "curren": "\u{00A4}", "sect": "\u{00A7}", "para": "\u{00B6}", "iexcl": "\u{00A1}", "iquest": "\u{00BF}",
        "frac12": "\u{00BD}", "frac14": "\u{00BC}", "frac34": "\u{00BE}", "check": "\u{2713}",
        // Not HTML, but left behind by some bank templates.
        "rupee": "\u{20B9}", "inr": "\u{20B9}",
    ]

    /// Names that browsers also accept without the closing semicolon.
    private static let legacyEntities: Set<String> = ["amp", "lt", "gt", "quot", "nbsp", "copy", "reg"]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let scalars = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            guard c == "&" else { out.append(c); i += 1; continue }
            var j = i + 1
            var name = ""
            while j < scalars.count, j - i <= 32, isEntityScalar(scalars[j]) {
                name.unicodeScalars.append(scalars[j])
                j += 1
            }
            let terminated = j < scalars.count && scalars[j] == ";"
            if let value = entityValue(name, terminated: terminated) {
                out.append(contentsOf: value.unicodeScalars)
                i = terminated ? j + 1 : j
            } else {
                out.append(c)
                i += 1
            }
        }
        return String(out)
    }

    private static func isEntityScalar(_ u: Unicode.Scalar) -> Bool {
        (u.value >= 0x30 && u.value <= 0x39) || (u.value >= 0x41 && u.value <= 0x5A)
            || (u.value >= 0x61 && u.value <= 0x7A) || u == "#"
    }

    private static func entityValue(_ name: String, terminated: Bool) -> String? {
        if name.hasPrefix("#") {
            var digits = name.dropFirst()
            var radix = 10
            if digits.first == "x" || digits.first == "X" { digits = digits.dropFirst(); radix = 16 }
            guard !digits.isEmpty, let code = UInt32(digits, radix: radix) else { return nil }
            if code >= 0x80 && code <= 0x9F {                                // windows-1252 numbers, as browsers do
                return String(bytes: [UInt8(code)], encoding: .windowsCP1252) ?? ""
            }
            guard code != 0, let scalar = Unicode.Scalar(code) else { return "\u{FFFD}" }
            return String(Character(scalar))
        }
        if !terminated && !legacyEntities.contains(name) { return nil }
        return namedEntities[name] ?? namedEntities[name.lowercased()]
    }

    // MARK: - Whitespace

    /// Lines split at LF, CR LF or CR (on scalars, because "\r\n" is a single Character).
    static func splitLines(_ s: String) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        var afterCR = false
        for u in s.unicodeScalars {
            if u == "\n" && afterCR { afterCR = false; continue }
            afterCR = u == "\r"
            if u == "\n" || u == "\r" {
                result.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(u)
            }
        }
        result.append(String(current))
        return result
    }

    /// format=flowed (RFC 3676): a line ending in a space continues on the next line.
    static func unflow(_ lines: [String], deleteSpace: Bool) -> [String] {
        var out: [String] = []
        var current: String?
        for var line in lines {
            if line.hasPrefix(" ") { line.removeFirst() }                    // space-stuffing
            let soft = line.hasSuffix(" ") && line != "-- "
            if soft && deleteSpace { line.removeLast() }
            let joined = (current ?? "") + line
            if soft { current = joined } else { out.append(joined); current = nil }
        }
        if let c = current { out.append(c) }
        return out
    }

    /// Collapses spaces inside each line and drops empty lines (or keeps at most one between paragraphs).
    static func tidy(_ lines: [String], keepBlankLines: Bool) -> String {
        var out: [String] = []
        for line in lines {
            let l = collapseSpaces(line)
            if !l.isEmpty {
                out.append(l)
            } else if keepBlankLines, let last = out.last, !last.isEmpty {
                out.append("")
            }
        }
        while out.last == "" { out.removeLast() }
        return out.joined(separator: "\n")
    }

    /// Runs of spaces (including no-break and other Unicode spaces) become one space, ends are trimmed and
    /// invisible characters (zero-width spaces, soft hyphens, BOM, direction marks) are removed.
    static func collapseSpaces(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for u in s.unicodeScalars {
            switch u.value {
            case 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x2060, 0xFEFF, 0x00AD:
                continue
            case 0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0xA0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000:
                pendingSpace = !out.isEmpty
            default:
                if pendingSpace { out.append(" "); pendingSpace = false }
                out.append(u)
            }
        }
        return String(out)
    }

    private static func containsDigit(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value >= 0x30 && $0.value <= 0x39 }
    }
}
