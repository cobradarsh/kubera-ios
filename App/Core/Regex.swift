import Foundation

/// Small wrapper over NSRegularExpression (ICU syntax). Patterns are fixed strings, so a bad one is a programming
/// error: `tests/run.sh` builds every pattern on each CI run.
final class Rx {
    let re: NSRegularExpression
    let pattern: String

    init(_ pattern: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) {
        self.pattern = pattern
        do {
            re = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            fatalError("bad regex \(pattern): \(error)")
        }
    }

    /// Capture groups of the first match (index 0 = whole match), nil where a group did not take part.
    func match(_ s: String) -> [String?]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Rx.groups(m, ns)
    }

    func matches(_ s: String) -> [[String?]] {
        let ns = s as NSString
        return re.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length)).map { Rx.groups($0, ns) }
    }

    /// Matches with their ranges (for finding what precedes a match).
    func matchRanges(_ s: String) -> [(groups: [String?], range: NSRange)] {
        let ns = s as NSString
        return re.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length)).map { (Rx.groups($0, ns), $0.range) }
    }

    func test(_ s: String) -> Bool {
        re.firstMatch(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    func replace(_ s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }

    private static func groups(_ m: NSTextCheckingResult, _ ns: NSString) -> [String?] {
        var out: [String?] = []
        out.reserveCapacity(m.numberOfRanges)
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            out.append(r.location == NSNotFound ? nil : ns.substring(with: r))
        }
        return out
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// FNV-1a, the same on every launch (unlike `hashValue`).
    var stableHash: String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return String(h, radix: 16)
    }

    /// Collapses runs of whitespace (including newlines and NBSP) into single spaces.
    var collapsedSpaces: String {
        var out = ""
        out.reserveCapacity(count)
        var lastSpace = false
        for ch in self {
            if ch.isWhitespace || ch == "\u{00A0}" {
                if !lastSpace { out.append(" ") }
                lastSpace = true
            } else {
                out.append(ch)
                lastSpace = false
            }
        }
        return out.trimmed
    }
}
