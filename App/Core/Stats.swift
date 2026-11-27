import Foundation

struct CategoryTotal: Identifiable, Hashable {
    var id: String { category }
    var category: String
    var amount: Double
    var count: Int
}

struct DayTotal: Identifiable, Hashable {
    var id: Date { day }
    var day: Date
    var amount: Double
}

struct MonthCategoryTotal: Identifiable, Hashable {
    var id: String { Cal.dayKey(month) + category }
    var month: Date
    var category: String
    var amount: Double
}

struct MerchantTotal: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var amount: Double
    var count: Int
}

struct HeatCell: Identifiable, Hashable {
    var id: String { "\(weekday)-\(slot)" }
    var weekday: Int     // 1 = Monday
    var slot: Int        // 0…7, three-hour slots
    var amount: Double
}

/// Spending maths. Spending = debits minus credits in categories of kind "expense" (a refund lowers what was
/// spent); transfers and investments never count; duplicates and excluded items are skipped.
struct SpendStats {
    let txns: [Txn]
    let kinds: [String: CategoryKind]

    init(txns: [Txn], categories: [Category]) {
        self.txns = txns.filter { !$0.isDuplicate && !$0.excluded }
        var k: [String: CategoryKind] = [:]
        for c in categories { k[c.id] = c.kind }
        self.kinds = k
    }

    func kind(_ c: String) -> CategoryKind { kinds[c] ?? .expense }

    func isSpend(_ t: Txn) -> Bool { kind(t.category) == .expense }

    /// Positive for spending, negative for refunds.
    func spendValue(_ t: Txn) -> Double { isSpend(t) ? t.signedAmount : 0 }

    func inMonth(_ month: Date) -> [Txn] {
        let s = Cal.startOfMonth(month), e = Cal.endOfMonth(month)
        return txns.filter { $0.date >= s && $0.date <= e }
    }

    func inRange(_ s: Date, _ e: Date) -> [Txn] { txns.filter { $0.date >= s && $0.date <= e } }

    func spent(_ list: [Txn]) -> Double { list.reduce(0) { $0 + spendValue($1) } }

    func income(_ list: [Txn]) -> Double {
        list.filter { kind($0.category) == .income }.reduce(0) { $0 + ($1.direction == .credit ? $1.amount : -$1.amount) }
    }

    func invested(_ list: [Txn]) -> Double {
        list.filter { kind($0.category) == .investment }.reduce(0) { $0 + $1.signedAmount }
    }

    func byCategory(_ list: [Txn]) -> [CategoryTotal] {
        var m: [String: (Double, Int)] = [:]
        for t in list where isSpend(t) {
            let v = m[t.category] ?? (0, 0)
            m[t.category] = (v.0 + t.signedAmount, v.1 + 1)
        }
        return m.map { CategoryTotal(category: $0.key, amount: $0.value.0, count: $0.value.1) }
            .filter { $0.amount > 0.5 }
            .sorted { $0.amount > $1.amount }
    }

    /// Every day of the month (zeros included), up to today for the current month.
    func byDay(month: Date, now: Date = Date()) -> [DayTotal] {
        let list = inMonth(month)
        var m: [Date: Double] = [:]
        for t in list where isSpend(t) { m[Cal.startOfDay(t.date), default: 0] += t.signedAmount }
        let start = Cal.startOfMonth(month)
        var days = Cal.daysInMonth(month)
        if Cal.sameMonth(month, now) { days = Cal.day(now) }
        return (0..<days).map { i in
            let d = Cal.addDays(i, to: start)
            return DayTotal(day: d, amount: m[d] ?? 0)
        }
    }

    func cumulative(month: Date, now: Date = Date()) -> [DayTotal] {
        var run = 0.0
        return byDay(month: month, now: now).map { d in
            run += d.amount
            return DayTotal(day: d.day, amount: run)
        }
    }

    func byInstrument(_ list: [Txn]) -> [(Instrument, Double)] {
        var m: [Instrument: Double] = [:]
        for t in list where isSpend(t) && t.direction == .debit { m[t.instrument, default: 0] += t.amount }
        return m.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    func topMerchants(_ list: [Txn], limit: Int = 8) -> [MerchantTotal] {
        var m: [String: (Double, Int)] = [:]
        for t in list where isSpend(t) && t.direction == .debit {
            let n = t.counterparty.isEmpty ? "Unknown" : t.counterparty
            let v = m[n] ?? (0, 0)
            m[n] = (v.0 + t.amount, v.1 + 1)
        }
        return m.map { MerchantTotal(name: $0.key, amount: $0.value.0, count: $0.value.1) }
            .sorted { $0.amount > $1.amount }
            .prefix(limit).map { $0 }
    }

    func heat(_ list: [Txn]) -> [HeatCell] {
        var m: [String: Double] = [:]
        for t in list where isSpend(t) && t.direction == .debit {
            let k = "\(Cal.weekdayMon(t.date))-\(Cal.hour(t.date) / 3)"
            m[k, default: 0] += t.amount
        }
        var out: [HeatCell] = []
        for w in 1...7 {
            for s in 0..<8 { out.append(HeatCell(weekday: w, slot: s, amount: m["\(w)-\(s)"] ?? 0)) }
        }
        return out
    }

    /// Last `months` months, each split by category (top categories kept, the rest as "Other").
    func monthlyByCategory(endingAt month: Date, months: Int, keep: Int = 5) -> [MonthCategoryTotal] {
        let end = Cal.startOfMonth(month)
        let starts = (0..<months).map { Cal.addMonths(-(months - 1 - $0), to: end) }
        var totals: [String: Double] = [:]
        var cells: [String: [Date: Double]] = [:]
        for s in starts {
            for t in inMonth(s) where isSpend(t) {
                totals[t.category, default: 0] += t.signedAmount
                cells[t.category, default: [:]][s, default: 0] += t.signedAmount
            }
        }
        let top = Set(totals.sorted { $0.value > $1.value }.prefix(keep).map { $0.key })
        var out: [MonthCategoryTotal] = []
        for s in starts {
            var other = 0.0
            for (c, byMonth) in cells {
                let v = byMonth[s] ?? 0
                if top.contains(c) { out.append(MonthCategoryTotal(month: s, category: c, amount: max(0, v))) } else { other += v }
            }
            if other > 0.5 { out.append(MonthCategoryTotal(month: s, category: "other", amount: other)) }
        }
        return out
    }

    func weeklyByCategory(month: Date, keep: Int = 5) -> [(week: Int, category: String, amount: Double)] {
        let list = inMonth(month).filter { isSpend($0) }
        var totals: [String: Double] = [:]
        for t in list { totals[t.category, default: 0] += t.signedAmount }
        let top = Set(totals.sorted { $0.value > $1.value }.prefix(keep).map { $0.key })
        var m: [String: Double] = [:]
        for t in list {
            let w = (Cal.day(t.date) - 1) / 7 + 1
            let c = top.contains(t.category) ? t.category : "other"
            m["\(w)|\(c)", default: 0] += t.signedAmount
        }
        var out: [(week: Int, category: String, amount: Double)] = []
        for (k, v) in m {
            let p = k.split(separator: "|")
            guard p.count == 2, let w = Int(p[0]), v > 0 else { continue }
            out.append((week: w, category: String(p[1]), amount: v))
        }
        return out.sorted { $0.week < $1.week }
    }
}

/// Trading maths over daily results.
struct TradeStats {
    let days: [TradeDay]

    init(days: [TradeDay]) { self.days = days.sorted { $0.date < $1.date } }

    /// One number per date (all brokers together).
    var byDate: [(date: Date, pnl: Double, net: Double)] {
        var m: [Date: (Double, Double)] = [:]
        for d in days {
            let v = m[d.date] ?? (0, 0)
            m[d.date] = (v.0 + d.pnl, v.1 + d.net)
        }
        return m.sorted { $0.key < $1.key }.map { ($0.key, $0.value.0, $0.value.1) }
    }

    var gross: Double { days.reduce(0) { $0 + $1.pnl } }
    var charges: Double { days.reduce(0) { $0 + ($1.charges ?? 0) } }
    var net: Double { gross - charges }

    var winDays: Int { byDate.filter { $0.net > 0 }.count }
    var lossDays: Int { byDate.filter { $0.net < 0 }.count }
    var tradingDays: Int { byDate.count }
    var winRate: Double { tradingDays == 0 ? 0 : Double(winDays) / Double(tradingDays) }
    var best: (date: Date, net: Double)? { byDate.max { $0.net < $1.net }.map { ($0.date, $0.net) } }
    var worst: (date: Date, net: Double)? { byDate.min { $0.net < $1.net }.map { ($0.date, $0.net) } }
    var avgWin: Double {
        let w = byDate.filter { $0.net > 0 }
        return w.isEmpty ? 0 : w.reduce(0) { $0 + $1.net } / Double(w.count)
    }
    var avgLoss: Double {
        let l = byDate.filter { $0.net < 0 }
        return l.isEmpty ? 0 : l.reduce(0) { $0 + $1.net } / Double(l.count)
    }
    /// Sum of winning days / |sum of losing days|.
    var profitFactor: Double? {
        let w = byDate.filter { $0.net > 0 }.reduce(0) { $0 + $1.net }
        let l = abs(byDate.filter { $0.net < 0 }.reduce(0) { $0 + $1.net })
        return l < 0.01 ? nil : w / l
    }

    var equityCurve: [(date: Date, value: Double)] {
        var run = 0.0
        return byDate.map { run += $0.net; return ($0.date, run) }
    }

    /// Largest fall from a running peak of the equity curve (a negative number or 0).
    var maxDrawdown: Double {
        var peak = 0.0, dd = 0.0
        for p in equityCurve {
            peak = max(peak, p.value)
            dd = min(dd, p.value - peak)
        }
        return dd
    }

    var streaks: (win: Int, loss: Int) {
        var bw = 0, bl = 0, cw = 0, cl = 0
        for d in byDate {
            if d.net > 0 { cw += 1; cl = 0 } else if d.net < 0 { cl += 1; cw = 0 } else { cw = 0; cl = 0 }
            bw = max(bw, cw); bl = max(bl, cl)
        }
        return (bw, bl)
    }

    func byWeekday() -> [(weekday: Int, net: Double)] {
        var m: [Int: Double] = [:]
        for d in byDate { m[Cal.weekdayMon(d.date), default: 0] += d.net }
        return (1...5).map { ($0, m[$0] ?? 0) }
    }

    func byBroker() -> [(broker: String, net: Double)] {
        var m: [String: Double] = [:]
        for d in days { m[d.broker, default: 0] += d.net }
        return m.sorted { abs($0.value) > abs($1.value) }.map { ($0.key, $0.value) }
    }

    /// Underlying of each position ("NIFTY", "SENSEX", "CRUDEOIL" …) and its total.
    func byUnderlying() -> [(name: String, pnl: Double)] {
        var m: [String: Double] = [:]
        for d in days {
            for p in d.positions {
                let u = p.symbol.split(separator: " ").first.map(String.init) ?? p.symbol
                m[u.uppercased(), default: 0] += p.pnl
            }
        }
        return m.sorted { abs($0.value) > abs($1.value) }.map { ($0.key, $0.value) }
    }
}
