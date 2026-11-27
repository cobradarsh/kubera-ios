import Foundation

/// A line of text found in a screenshot by the on-device text recogniser.
struct OCRLine: Hashable {
    var text: String
    /// Normalised box, origin top-left, 0…1.
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    /// Colour of the text itself when known (sampled from the picture): +1 green, -1 red, 0 neither.
    var tint: Int = 0

    var midY: Double { y + h / 2 }
    var maxX: Double { x + w }
}

enum ScreenKind: String, Codable { case positions, holdings, unknown }

struct TradeReading: Hashable {
    var broker: String?
    var kind: ScreenKind
    /// Signed total profit/loss of the screen (positions: the day's P&L; holdings: overall returns).
    var total: Double?
    /// Holdings only: current value and invested amount.
    var currentValue: Double?
    var invested: Double?
    var positions: [PositionPnL]
    /// 0…1: how sure the reader is about `total`.
    var confidence: Double
    var notes: [String]
    /// Rows are MCX commodities, whose evening session also runs on most NSE holidays.
    var commodity: Bool = false
}

/// Reads broker screenshots (Dhan, Kite, Kotak Neo, Upstox, Groww, Angel One …) from recognised text lines.
///
/// The total is the number next to (right of, or just below) a "P&L" / "Total P&L" / "Returns" label, preferring the
/// largest such number near the top. Its sign comes from a "+"/"-" in the text, else from the text colour.
enum TradeOCRParser {

    static let brokers: [(String, [String])] = [
        ("Dhan", ["dhan", "dhanhq"]),
        ("Kite", ["kite", "zerodha"]),
        ("Kotak Neo", ["kotak neo", "neo", "kotak securities"]),
        ("Upstox", ["upstox"]),
        ("Groww", ["groww"]),
        ("Angel One", ["angel one", "angelone", "angel"]),
        ("ICICI Direct", ["icicidirect", "icici direct"]),
        ("Fyers", ["fyers"]),
        ("5paisa", ["5paisa"]),
        ("Sensibull", ["sensibull"]),
    ]

    private static let numberRx = Rx(#"([+\-−]?)\s*(?:₹|Rs\.?|INR)?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)\s*(%|[+\-−])?"#)
    private static let labelRx = Rx(#"(total\s*p\s*[&n]\s*l|overall\s*p\s*[&n]\s*l|today'?s\s*p\s*[&n]\s*l|day'?s\s*p\s*[&n]\s*l|net\s*p\s*[&n]\s*l|realised\s*p\s*[&n]\s*l|realized\s*p\s*[&n]\s*l|unrealised|unrealized|\bp\s*&\s*l\b|\bpnl\b|\bp/l\b|total returns|overall returns|total profit|total loss|m2m|mtm)"#)
    private static let symbolRx = Rx(#"\b(NIFTY|BANKNIFTY|FINNIFTY|MIDCPNIFTY|SENSEX|BANKEX|CRUDEOIL|CRUDEOILM|NATURALGAS|NATGASMINI|GOLD|GOLDM|GOLDPETAL|SILVER|SILVERM|SILVERMIC|COPPER|ZINC|ALUMINIUM|LEAD|USDINR)\b[^\n]*"#, [.caseInsensitive])
    private static let optionRx = Rx(#"\b(CE|PE|FUT|CALL|PUT)\b"#, [.caseInsensitive])
    private static let mcxNames: Set<String> = ["CRUDEOIL", "CRUDEOILM", "NATURALGAS", "NATGASMINI", "GOLD", "GOLDM", "GOLDPETAL",
                                                "SILVER", "SILVERM", "SILVERMIC", "COPPER", "ZINC", "ALUMINIUM", "LEAD"]

    static func detectBroker(_ lines: [OCRLine]) -> String? {
        let all = lines.map { $0.text.lowercased() }.joined(separator: " \n ")
        for (name, keys) in brokers {
            for k in keys {
                if k.count <= 4 {
                    if all.range(of: "\\b\(k)\\b", options: .regularExpression) != nil { return name }
                } else if all.contains(k) { return name }
            }
        }
        return nil
    }

    static func detectKind(_ lines: [OCRLine]) -> ScreenKind {
        let all = lines.map { $0.text.lowercased() }.joined(separator: " ")
        let pos = all.contains("position") || all.contains("open positions") || all.contains("closed positions")
        let hold = all.contains("holding") || all.contains("current value") || all.contains("invested")
        if pos && !hold { return .positions }
        if hold && !pos { return .holdings }
        if pos && hold {
            // Both words appear on tab bars; the selected screen usually also shows its own labels.
            if all.contains("current value") || all.contains("invested") { return .holdings }
            return .positions
        }
        if symbolRx.test(all) && optionRx.test(all) { return .positions }
        return .unknown
    }

    /// Numbers in a line with their sign. When the line has amounts written like money ("66,753.00"), small bare
    /// counts beside them ("on 1 positions") and a misread rupee sign ("2 66,753.00") are left out.
    static func numbers(in line: OCRLine) -> [Double] {
        var all: [(value: Double, money: Bool)] = []
        for g in numberRx.matches(line.text) {
            guard let raw = g[2], let v = Money.parse(raw) else { continue }
            let pre = g[1] ?? "", post = g[3] ?? ""
            if post == "%" { continue }   // "(+2.50%)" next to the amount
            var sign = 0.0
            if pre == "-" || pre == "−" || post == "-" || post == "−" { sign = -1 }
            else if pre == "+" || post == "+" { sign = 1 }
            else if line.tint != 0 { sign = Double(line.tint) }
            all.append((sign == 0 ? v : sign * v, raw.contains(",") || raw.contains(".") || v >= 1000))
        }
        let money = all.filter { $0.money }
        return (money.isEmpty ? all : money).map { $0.value }
    }

    private static func isPercentOnly(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespaces).hasSuffix("%") && s.filter({ $0.isNumber }).count <= 5
    }

    static func read(_ lines: [OCRLine]) -> TradeReading {
        let sorted = lines.sorted { $0.y < $1.y }
        var notes: [String] = []
        let broker = detectBroker(sorted)
        let kind = detectKind(sorted)
        if broker == nil { notes.append("Broker not recognised") }

        // Labels and the number that belongs to each.
        var candidates: [(value: Double, score: Double, label: String)] = []
        for (i, l) in sorted.enumerated() {
            guard let g = labelRx.match(l.text.lowercased()), let label = g[1] else { continue }
            var score = 1.0
            let isTotal = label.contains("total") || label.contains("overall") || label.contains("net")
            let isDay = label.contains("day") || label == "m2m" || label == "mtm"
            if kind == .holdings {
                if isTotal { score += 2 }
                if isDay { score += 1 }
            } else {
                // Positions: the day's figure beats "overall", which also counts earlier days of carried positions.
                if isDay { score += 3 }
                if isTotal { score += 2 }
            }
            if label.contains("unreal") { score -= 0.5 }
            score += max(0, 0.6 - l.y)  // near the top
            // Same line, right of the label.
            let sameLine = numbers(in: OCRLine(text: String(l.text.lowercased().components(separatedBy: label).last ?? ""),
                                               x: l.x, y: l.y, w: l.w, h: l.h, tint: l.tint))
            if let v = sameLine.first {
                candidates.append((v, score + 0.5, label)); continue
            }
            // Lines just below (within 9% of the height, in the label's own column) or to the right on the same row.
            var best: (Double, Double)?
            for j in max(0, i - 3)..<min(sorted.count, i + 6) where j != i {
                let o = sorted[j]
                if isPercentOnly(o.text) { continue }
                let dy = o.midY - l.midY
                let sameRow = abs(dy) < max(l.h, o.h) * 0.6 && o.x > l.x
                let sameColumn = (o.x < l.maxX + 0.02 && o.maxX > l.x - 0.02) || abs(o.x - l.x) < 0.12
                let below = dy > 0 && dy < 0.09 && sameColumn
                guard sameRow || below else { continue }
                guard let v = numbers(in: o).first else { continue }
                // Bigger text ranks higher; nearer text wins a tie.
                let s = score + (sameRow ? 0.4 : 0.2) + min(0.5, o.h * 8) - abs(o.x - l.x) * 0.3 - max(0, dy) * 2
                if best == nil || s > best!.1 { best = (v, s) }
            }
            if let b = best { candidates.append((b.0, b.1, label)) }
        }

        var total: Double?
        var confidence = 0.0
        if let top = candidates.max(by: { $0.score < $1.score }) {
            total = top.value
            confidence = min(1, 0.45 + top.score / 8)
            notes.append("Total from \"\(top.label)\"")
        }

        // Holdings: current value / invested.
        var current: Double?
        var invested: Double?
        if kind == .holdings {
            current = valueNear(label: "current value", in: sorted) ?? valueNear(label: "current", in: sorted)
            invested = valueNear(label: "invested", in: sorted)
            if total == nil, let c = current, let i = invested { total = c - i; confidence = max(confidence, 0.6) }
        }

        // Position rows: an instrument name and a signed number on the same row, right half.
        var positions: [PositionPnL] = []
        if kind != .holdings {
            for l in sorted {
                guard let g = symbolRx.match(l.text), let whole = g[0] else { continue }
                let symbol = whole.trimmed.prefix(40)
                // A number on the same row at the right edge.
                let row = sorted.filter { abs($0.midY - l.midY) < max($0.h, l.h) * 0.8 && $0.x > l.x + l.w * 0.5 }
                if let rightmost = row.max(by: { $0.maxX < $1.maxX }), let v = numbers(in: rightmost).last {
                    positions.append(PositionPnL(symbol: String(symbol), pnl: v))
                }
            }
            if total == nil && !positions.isEmpty {
                total = positions.reduce(0) { $0 + $1.pnl }
                confidence = 0.4
                notes.append("Total is the sum of the rows")
            }
        }
        if let t = total, positions.count >= 2 {
            let sum = positions.reduce(0) { $0 + $1.pnl }
            if abs(sum - t) < max(1, abs(t) * 0.01) { confidence = min(1, confidence + 0.2); notes.append("Rows add up to the total") }
        }
        if total == nil { notes.append("No P&L found") }
        let commodity = positions.contains { p in mcxNames.contains(p.symbol.split(separator: " ").first.map { String($0).uppercased() } ?? "") }
        return TradeReading(broker: broker, kind: kind, total: total, currentValue: current, invested: invested,
                            positions: positions, confidence: confidence, notes: notes, commodity: commodity)
    }

    private static func valueNear(label: String, in sorted: [OCRLine]) -> Double? {
        for (i, l) in sorted.enumerated() where l.text.lowercased().contains(label) {
            let rest = String(l.text.lowercased().components(separatedBy: label).last ?? "")
            if let v = numbers(in: OCRLine(text: rest, x: l.x, y: l.y, w: l.w, h: l.h)).first { return abs(v) }
            for j in (i + 1)..<min(sorted.count, i + 4) {
                let o = sorted[j]
                if o.midY - l.midY < 0.08, abs(o.x - l.x) < 0.3, let v = numbers(in: o).first { return abs(v) }
            }
        }
        return nil
    }
}
