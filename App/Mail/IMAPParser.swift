// IMAPParser.swift - Kubera
// Pure (Foundation only): cuts the byte stream from an IMAP server into responses and parses them
// (RFC 3501). Works on bytes, not String, because message bodies arrive as literals of arbitrary bytes.

import Foundation

/// One value in an IMAP response.
public enum IMAPValue: Equatable {
    /// Atom or number as sent: OK, FETCH, 42, \All, NIL, BODY[]<0>.
    case atom(String)
    /// Quoted string or literal, as raw bytes.
    case string(Data)
    /// Parenthesised list.
    case list([IMAPValue])

    /// Text of an atom or string (UTF-8, else ISO-8859-1); nil for NIL and for lists.
    public var text: String? {
        switch self {
        case .atom(let a): return a.uppercased() == "NIL" ? nil : a
        case .string(let d): return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1)
        case .list: return nil
        }
    }

    /// Bytes of a string or literal; nil for NIL, atoms and lists.
    public var data: Data? {
        if case .string(let d) = self { return d }
        return nil
    }

    public var number: UInt32? {
        if case .atom(let a) = self { return UInt32(a) }
        return nil
    }
}

public struct IMAPResponse: Equatable {
    public enum Kind: Equatable {
        case untagged            // "* ..."
        case continuation        // "+ ..."
        case tagged(String)      // "<tag> OK|NO|BAD ..."
    }

    public var kind: Kind
    /// OK, NO, BAD, PREAUTH or BYE (upper-cased) for status responses; nil for data responses.
    public var status: String?
    /// Text inside the [ ] response code, e.g. "UIDVALIDITY 654321"; nil when there is none.
    public var code: String?
    /// Human-readable text of a status or continuation response.
    public var text: String
    /// Values of a data response, e.g. [SEARCH, 3, 10] or [12, FETCH, (UID 7 ...)].
    public var values: [IMAPValue]

    public init(kind: Kind, status: String? = nil, code: String? = nil, text: String = "", values: [IMAPValue] = []) {
        self.kind = kind
        self.status = status
        self.code = code
        self.text = text
        self.values = values
    }
}

public struct IMAPParseError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Collects bytes as they arrive and returns complete responses. A line ending in `{n}` announces a literal:
/// the next n bytes (which may contain CRLF) belong to the same response, which goes on after them.
public struct IMAPResponseFramer {
    private var buffer: [UInt8] = []
    private var start = 0      // first byte of the response being collected
    private var scan = 0       // where to resume looking for its end
    /// Refuse responses larger than this (a broken or hostile server).
    public var maxResponseSize = 64 << 20

    public init() {}

    public var bufferedByteCount: Int { buffer.count - start }

    public mutating func append(_ data: Data) { buffer.append(contentsOf: data) }

    public mutating func append(_ bytes: [UInt8]) { buffer.append(contentsOf: bytes) }

    /// The next complete response without its final CRLF, or nil when more bytes are needed.
    public mutating func next() throws -> [UInt8]? {
        var i = Swift.max(scan, start)
        while let lf = buffer[i...].firstIndex(of: 0x0A) {
            var end = lf
            if end > start, buffer[end - 1] == 0x0D { end -= 1 }
            if let n = try literalLength(endingAt: end) {
                let after = lf + 1 + n
                if after > buffer.count {
                    scan = lf                      // look at this line again when more bytes are in
                    return nil
                }
                i = after                          // the response continues after the literal
                continue
            }
            let response = Array(buffer[start..<end])
            start = lf + 1
            scan = start
            compact()
            return response
        }
        scan = buffer.count
        if buffer.count - start > maxResponseSize { throw IMAPParseError("response too large") }
        return nil
    }

    /// n when the bytes before `end` are "{n}" or "{n+}".
    private func literalLength(endingAt end: Int) throws -> Int? {
        var j = end - 1
        guard j > start, buffer[j] == 0x7D else { return nil }          // }
        j -= 1
        if buffer[j] == 0x2B { j -= 1 }                                 // + (LITERAL+)
        var n = 0
        var digits = 0
        var scale = 1
        while j >= start, buffer[j] >= 0x30, buffer[j] <= 0x39 {
            digits += 1
            guard digits <= 10 else { throw IMAPParseError("literal too large") }
            n += Int(buffer[j] - 0x30) * scale
            scale *= 10
            j -= 1
        }
        guard digits > 0, j >= start, buffer[j] == 0x7B else { return nil }   // {
        guard n <= maxResponseSize else { throw IMAPParseError("literal too large") }
        return n
    }

    private mutating func compact() {
        guard start > 0 else { return }
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
        } else if start >= 1 << 20 || start * 2 >= buffer.count {
            buffer.removeFirst(start)
        } else {
            return
        }
        scan -= start
        start = 0
    }
}

public struct IMAPFetch: Equatable {
    public var sequence: UInt32
    public var uid: UInt32?
    public var internalDate: Date?
    /// BODY[] (or BODY[]<0>) bytes; nil when absent or NIL.
    public var body: Data?
}

public struct IMAPMailbox: Equatable {
    /// Attributes as sent, e.g. \HasNoChildren, \All.
    public var attributes: [String]
    public var delimiter: String?
    /// Name as sent (modified UTF-7); send it back unchanged.
    public var name: String

    public func hasAttribute(_ attribute: String) -> Bool {
        attributes.contains { $0.caseInsensitiveCompare(attribute) == .orderedSame }
    }
}

public enum IMAPParser {
    private static let statusWords: Set<String> = ["OK", "NO", "BAD", "PREAUTH", "BYE"]

    /// Parses one response as returned by `IMAPResponseFramer.next()`.
    public static func parseResponse(_ bytes: [UInt8]) throws -> IMAPResponse {
        guard let first = bytes.first else { throw IMAPParseError("empty response") }
        if first == 0x2B {                                              // +
            var i = 1
            if i < bytes.count, bytes[i] == 0x20 { i += 1 }
            return IMAPResponse(kind: .continuation, text: String(decoding: bytes[i...], as: UTF8.self))
        }
        let tagEnd = bytes.firstIndex(of: 0x20) ?? bytes.count
        let tag = String(decoding: bytes[0..<tagEnd], as: UTF8.self)
        let kind: IMAPResponse.Kind = tag == "*" ? .untagged : .tagged(tag)
        var i = tagEnd
        while i < bytes.count, bytes[i] == 0x20 { i += 1 }
        var wordEnd = i
        while wordEnd < bytes.count, bytes[wordEnd] != 0x20 { wordEnd += 1 }
        let word = String(decoding: bytes[i..<wordEnd], as: UTF8.self).uppercased()

        if statusWords.contains(word) {
            i = wordEnd
            while i < bytes.count, bytes[i] == 0x20 { i += 1 }
            var code: String?
            if i < bytes.count, bytes[i] == 0x5B, let close = matchingBracket(bytes, from: i) {   // [
                code = String(decoding: bytes[(i + 1)..<close], as: UTF8.self)
                i = close + 1
                while i < bytes.count, bytes[i] == 0x20 { i += 1 }
            }
            return IMAPResponse(kind: kind, status: word, code: code,
                                text: String(decoding: bytes[i...], as: UTF8.self))
        }
        guard case .untagged = kind else { throw IMAPParseError("tagged response without a status") }
        var tokenizer = Tokenizer(bytes: bytes, index: i)
        do {
            let values = try tokenizer.readValues()
            return IMAPResponse(kind: .untagged, values: values)
        } catch {
            // Something this reader does not understand: keep the first word and the text.
            return IMAPResponse(kind: .untagged, text: String(decoding: bytes[i...], as: UTF8.self),
                                values: [.atom(word)])
        }
    }

    private static func matchingBracket(_ b: [UInt8], from open: Int) -> Int? {
        var depth = 0
        var j = open
        while j < b.count {
            if b[j] == 0x5B { depth += 1 }
            if b[j] == 0x5D { depth -= 1; if depth == 0 { return j } }
            j += 1
        }
        return nil
    }

    /// UIDs of a "* SEARCH 3 10 42" response; nil when `r` is not one.
    public static func searchResults(_ r: IMAPResponse) -> [UInt32]? {
        guard r.kind == .untagged, r.status == nil, let first = r.values.first,
              case .atom(let word) = first, word.uppercased() == "SEARCH" else { return nil }
        return r.values.dropFirst().compactMap { $0.number }
    }

    /// "* 12 FETCH (UID 345 INTERNALDATE "..." BODY[]<0> {n}...)"; nil when `r` is not a FETCH.
    public static func fetchResult(_ r: IMAPResponse) -> IMAPFetch? {
        guard r.kind == .untagged, r.status == nil, r.values.count >= 3, let sequence = r.values[0].number,
              case .atom(let word) = r.values[1], word.uppercased() == "FETCH",
              case .list(let items) = r.values[2] else { return nil }
        var fetch = IMAPFetch(sequence: sequence, uid: nil, internalDate: nil, body: nil)
        var k = 0
        while k + 1 < items.count {
            guard case .atom(let rawKey) = items[k] else { k += 1; continue }
            let key = rawKey.uppercased()
            let value = items[k + 1]
            if key == "UID" {
                fetch.uid = value.number
            } else if key == "INTERNALDATE" {
                fetch.internalDate = value.text.flatMap(parseInternalDate)
            } else if key.hasPrefix("BODY[") || key.hasPrefix("BINARY[") || key == "RFC822" {
                if fetch.body == nil || key.hasPrefix("BODY[]") { fetch.body = value.data }
            }
            k += 2
        }
        return fetch
    }

    /// "* LIST (\HasNoChildren \All) "/" "[Gmail]/All Mail""; nil when `r` is not a LIST (or XLIST).
    public static func listResult(_ r: IMAPResponse) -> IMAPMailbox? {
        guard r.kind == .untagged, r.status == nil, r.values.count >= 4,
              case .atom(let word) = r.values[0], ["LIST", "XLIST"].contains(word.uppercased()),
              case .list(let attributes) = r.values[1], let name = r.values[3].text else { return nil }
        return IMAPMailbox(attributes: attributes.compactMap { $0.text }, delimiter: r.values[2].text, name: name)
    }

    /// The argument of a response code such as [UIDVALIDITY 654321] ("" when it has none).
    public static func codeArgument(_ r: IMAPResponse, _ name: String) -> String? {
        guard let code = r.code else { return nil }
        let parts = code.split(separator: " ", maxSplits: 1)
        guard let first = parts.first, first.uppercased() == name.uppercased() else { return nil }
        return parts.count > 1 ? String(parts[1]) : ""
    }

    public static func uidValidity(_ r: IMAPResponse) -> UInt32? {
        codeArgument(r, "UIDVALIDITY").flatMap { UInt32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Upper-cased capabilities from "* CAPABILITY ..." or an [CAPABILITY ...] response code.
    public static func capabilities(_ r: IMAPResponse) -> Set<String>? {
        if r.kind == .untagged, r.status == nil, let first = r.values.first,
           case .atom(let word) = first, word.uppercased() == "CAPABILITY" {
            return Set(r.values.dropFirst().compactMap { $0.text?.uppercased() })
        }
        if let argument = codeArgument(r, "CAPABILITY") {
            return Set(argument.split(separator: " ").map { $0.uppercased() })
        }
        return nil
    }

    private static let internalDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return f
    }()

    /// INTERNALDATE such as " 5-Nov-2026 10:15:30 +0530" (the day may be space-padded).
    public static func parseInternalDate(_ s: String) -> Date? {
        internalDateFormatter.date(from: s.trimmingCharacters(in: .whitespaces))
    }

    /// `s` as an IMAP quoted string with \ and " escaped, or nil when it must be sent as a literal
    /// (non-ASCII, CR, LF or NUL).
    public static func quoted(_ s: String) -> String? {
        var out = "\""
        for u in s.unicodeScalars {
            if u.value >= 0x80 || u.value == 0 || u.value == 0x0A || u.value == 0x0D { return nil }
            if u == "\"" || u == "\\" { out.unicodeScalars.append("\\") }
            out.unicodeScalars.append(u)
        }
        out += "\""
        return out
    }

    /// Reads atoms, quoted strings, literals and lists from the bytes of one response.
    private struct Tokenizer {
        let bytes: [UInt8]
        var index: Int

        mutating func readValues() throws -> [IMAPValue] {
            var values: [IMAPValue] = []
            while true {
                skipSpaces()
                if index >= bytes.count { return values }
                values.append(try readValue())
            }
        }

        private mutating func skipSpaces() {
            while index < bytes.count, bytes[index] == 0x20 { index += 1 }
        }

        private mutating func readValue() throws -> IMAPValue {
            switch bytes[index] {
            case 0x28: return .list(try readList())                     // (
            case 0x22: return .string(try readQuoted())                 // "
            case 0x7B: return .string(try readLiteral())                // {
            case 0x29: throw IMAPParseError("unexpected )")
            default: return .atom(try readAtom())
            }
        }

        private mutating func readList() throws -> [IMAPValue] {
            index += 1
            var items: [IMAPValue] = []
            while true {
                skipSpaces()
                guard index < bytes.count else { throw IMAPParseError("unterminated list") }
                if bytes[index] == 0x29 { index += 1; return items }
                items.append(try readValue())
            }
        }

        private mutating func readQuoted() throws -> Data {
            index += 1
            var out: [UInt8] = []
            while index < bytes.count {
                let c = bytes[index]
                if c == 0x5C, index + 1 < bytes.count {                 // backslash escape
                    out.append(bytes[index + 1])
                    index += 2
                    continue
                }
                index += 1
                if c == 0x22 { return Data(out) }
                out.append(c)
            }
            throw IMAPParseError("unterminated quoted string")
        }

        private mutating func readLiteral() throws -> Data {
            index += 1
            var n = 0
            var digits = 0
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39, digits < 10 {
                n = n * 10 + Int(bytes[index] - 0x30)
                digits += 1
                index += 1
            }
            if index < bytes.count, bytes[index] == 0x2B { index += 1 }              // {n+}
            guard digits > 0, index < bytes.count, bytes[index] == 0x7D else { throw IMAPParseError("bad literal") }
            index += 1
            if index < bytes.count, bytes[index] == 0x0D { index += 1 }
            guard index < bytes.count, bytes[index] == 0x0A else { throw IMAPParseError("literal without CRLF") }
            index += 1
            guard n <= bytes.count - index else { throw IMAPParseError("literal shorter than announced") }
            let data = Data(bytes[index..<(index + n)])
            index += n
            return data
        }

        /// An atom; brackets are kept whole, so BODY[HEADER.FIELDS (DATE)]<0> is one atom.
        private mutating func readAtom() throws -> String {
            let begin = index
            var depth = 0
            while index < bytes.count {
                let c = bytes[index]
                if c == 0x5B {
                    depth += 1
                } else if c == 0x5D {
                    if depth > 0 { depth -= 1 }
                } else if depth == 0, c == 0x20 || c == 0x28 || c == 0x29 || c == 0x22 || c == 0x7B
                            || c == 0x0D || c == 0x0A {
                    break
                }
                index += 1
            }
            guard index > begin else { throw IMAPParseError("empty atom") }
            return String(decoding: bytes[begin..<index], as: UTF8.self)
        }
    }
}
