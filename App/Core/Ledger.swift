import Foundation

struct LoanInfo: Codable, Hashable {
    var lender: String
    var emi: Double
    var nextDue: Date
    var account: String?
}

/// Everything the app keeps, in one Codable value (written to Application Support as JSON).
struct LedgerState: Codable {
    var version = 1
    var txns: [Txn] = []
    var rules: [String: Rule] = [:]
    var balances: [String: AccountBalance] = [:]
    var turnovers: [String: Turnover] = [:]
    var mandates: [MandateHint] = []
    var loans: [String: LoanInfo] = [:]
    var trades: [String: TradeDay] = [:]
    var manual: [ManualItem] = []
    var snapshots: [NetWorthSnapshot] = []
    var customCategories: [Category] = []
    var budgets: [String: Double] = [:]
    var userHolidays: [Holiday] = []
    /// Progress markers for each source.
    var lastSMSRowID: Int64 = 0
    var inboxOffsets: [String: UInt64] = [:]
    var mailUIDValidity: UInt32 = 0
    var mailHighestUID: UInt32 = 0
    var lastScreenshotScan: Date?
    var seenAssets: [String] = []
    var ignoredCount: Int = 0

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, txns, rules, balances, turnovers, mandates, loans, trades, manual, snapshots, customCategories, budgets,
             userHolidays, lastSMSRowID, inboxOffsets, mailUIDValidity, mailHighestUID, lastScreenshotScan, seenAssets, ignoredCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        txns = try c.decodeIfPresent([Txn].self, forKey: .txns) ?? []
        rules = try c.decodeIfPresent([String: Rule].self, forKey: .rules) ?? [:]
        balances = try c.decodeIfPresent([String: AccountBalance].self, forKey: .balances) ?? [:]
        turnovers = try c.decodeIfPresent([String: Turnover].self, forKey: .turnovers) ?? [:]
        mandates = try c.decodeIfPresent([MandateHint].self, forKey: .mandates) ?? []
        loans = try c.decodeIfPresent([String: LoanInfo].self, forKey: .loans) ?? [:]
        trades = try c.decodeIfPresent([String: TradeDay].self, forKey: .trades) ?? [:]
        manual = try c.decodeIfPresent([ManualItem].self, forKey: .manual) ?? []
        snapshots = try c.decodeIfPresent([NetWorthSnapshot].self, forKey: .snapshots) ?? []
        customCategories = try c.decodeIfPresent([Category].self, forKey: .customCategories) ?? []
        budgets = try c.decodeIfPresent([String: Double].self, forKey: .budgets) ?? [:]
        userHolidays = try c.decodeIfPresent([Holiday].self, forKey: .userHolidays) ?? []
        lastSMSRowID = try c.decodeIfPresent(Int64.self, forKey: .lastSMSRowID) ?? 0
        inboxOffsets = try c.decodeIfPresent([String: UInt64].self, forKey: .inboxOffsets) ?? [:]
        mailUIDValidity = try c.decodeIfPresent(UInt32.self, forKey: .mailUIDValidity) ?? 0
        mailHighestUID = try c.decodeIfPresent(UInt32.self, forKey: .mailHighestUID) ?? 0
        lastScreenshotScan = try c.decodeIfPresent(Date.self, forKey: .lastScreenshotScan)
        seenAssets = try c.decodeIfPresent([String].self, forKey: .seenAssets) ?? []
        ignoredCount = try c.decodeIfPresent(Int.self, forKey: .ignoredCount) ?? 0
    }
}

struct IngestReport {
    var messages = 0
    var added = 0
    var duplicates = 0
    var balances = 0
    var ignored = 0
    var other = 0
    var newUncategorized = 0
    var lookups: [String] = []         // counterparty keys worth a web lookup
    var addedIDs: [String] = []

    mutating func merge(_ o: IngestReport) {
        messages += o.messages; added += o.added; duplicates += o.duplicates; balances += o.balances
        ignored += o.ignored; other += o.other; newUncategorized += o.newUncategorized
        lookups += o.lookups; addedIDs += o.addedIDs
    }
}

/// The rules for turning messages into the ledger. Pure: no files, no UI, no network.
struct Ledger {
    var state: LedgerState
    let db: MerchantDB

    init(state: LedgerState, db: MerchantDB) {
        self.state = state
        self.db = db
    }

    var categories: [Category] { Category.builtIns + state.customCategories }

    var categoryKinds: [String: CategoryKind] {
        var m: [String: CategoryKind] = [:]
        for c in categories { m[c.id] = c.kind }
        return m
    }

    // MARK: Ingest

    mutating func ingest(_ messages: [RawMessage]) -> IngestReport {
        var report = IngestReport()
        var index = Set(state.txns.map { $0.id })
        var categorizer = makeCategorizer()
        for m in messages.sorted(by: { $0.date < $1.date }) {
            report.messages += 1
            let items = MessageParser.parse(m)
            for (i, item) in items.enumerated() {
                switch item {
                case .txn(let p):
                    let id = i == 0 ? m.id : "\(m.id)#\(i)"
                    if index.contains(id) { continue }
                    var t = Txn(id: id, date: p.when ?? m.date, amount: p.amount, direction: p.direction)
                    t.counterparty = p.counterparty ?? ""
                    t.vpa = p.vpa
                    t.counterpartyKey = Categorizer.key(counterparty: p.counterparty, vpa: p.vpa)
                    t.instrument = p.instrument
                    t.bank = p.bank
                    t.last4 = p.last4
                    t.ref = p.ref
                    t.balanceAfter = p.balanceAfter
                    t.raw = m.text
                    t.source = m.source
                    t.sender = m.sender
                    t.isPrimary = p.isPrimary
                    t.hint = p.hint
                    t.pattern = p.pattern
                    // Link repeats first: a notification may give the bank SMS a readable payee name.
                    let dup = linkDuplicate(&t)
                    if dup { report.duplicates += 1 }
                    apply(categorizer.categorize(t, hint: t.hint), to: &t)
                    state.txns.append(t)
                    index.insert(id)
                    report.added += 1
                    report.addedIDs.append(id)
                    if !t.isDuplicate && t.direction == .debit && t.category == Category.uncategorized {
                        report.newUncategorized += 1
                        if t.lookupState == .pending && !t.counterpartyKey.isEmpty { report.lookups.append(t.counterpartyKey) }
                    }
                    if let v = t.vpa?.lowercased(), !v.hasPrefix("*"), learnable(t.categorySource) {
                        categorizer.knownVPAs[v] = (t.category, t.counterparty)
                    }
                case let .balance(inst, last4, kind, amount, asOf):
                    updateBalance(institution: inst, last4: last4, kind: kind, amount: amount, asOf: asOf)
                    report.balances += 1
                case let .brokerBalance(broker, fund, securities, asOf):
                    updateBalance(institution: broker, last4: nil, kind: .broker, amount: fund + securities, asOf: asOf)
                    report.balances += 1
                case .turnover(let t):
                    state.turnovers[t.id] = t
                    report.other += 1
                case .mandate(let h):
                    if !state.mandates.contains(where: { abs($0.amount - h.amount) < 0.01 && Cal.sameDay($0.due, h.due) }) {
                        state.mandates.append(h)
                    }
                    // Keep the newest notices by count, not by today's date: history is read months later.
                    if state.mandates.count > 300 {
                        state.mandates.sort { $0.due < $1.due }
                        state.mandates.removeFirst(state.mandates.count - 300)
                    }
                    report.other += 1
                case let .loanDue(lender, amount, due, account):
                    state.loans[lender] = LoanInfo(lender: lender, emi: amount, nextDue: due, account: account)
                    report.other += 1
                case .ignored:
                    report.ignored += 1
                    state.ignoredCount += 1
                }
            }
        }
        // Mandate notices can arrive a day before the debit they explain: sort again what is still unsorted.
        if report.added > 0 { recategorize(onlyUnsorted: true) }
        state.txns.sort { $0.date < $1.date }
        return report
    }

    func makeCategorizer() -> Categorizer {
        var known: [String: (category: String, name: String?)] = [:]
        for t in state.txns where !t.isDuplicate && learnable(t.categorySource) {
            if let v = t.vpa?.lowercased(), !v.hasPrefix("*"), t.category != Category.uncategorized {
                known[v] = (t.category, t.counterparty)
            }
        }
        return Categorizer(db: db, rules: state.rules, knownVPAs: known, mandates: state.mandates, categoryKinds: categoryKinds)
    }

    private func learnable(_ s: CategorySource) -> Bool {
        s == .user || s == .rule || s == .merchant || s == .claude || s == .web
    }

    private func apply(_ r: Categorization, to t: inout Txn) {
        guard t.categorySource != .user else { return }
        t.category = r.category
        t.categorySource = r.source
        if let n = r.displayName, !n.isEmpty { t.counterparty = n }
        t.isPerson = r.isPerson
        if r.suggestion != nil { t.suggestion = r.suggestion }
        if r.category != Category.uncategorized { t.suggestion = nil; t.suggestionNote = nil }
        if r.wantsLookup && t.lookupState == .none { t.lookupState = .pending }
    }

    // MARK: Duplicates

    /// Links `t` to an existing record of the same payment, or an existing confirmation to `t`.
    /// Two primary records (two bank SMS) are never merged unless they carry the same reference number.
    mutating func linkDuplicate(_ t: inout Txn) -> Bool {
        // Same reference number.
        if let r = t.ref, r.count >= 6,
           let j = state.txns.lastIndex(where: { $0.ref == r && $0.direction == t.direction && abs($0.amount - t.amount) < 0.01 && $0.duplicateOf == nil }) {
            merge(newer: &t, existingAt: j)
            return true
        }
        var best: (index: Int, gap: TimeInterval)?
        for (j, c) in state.txns.enumerated().reversed() {
            if c.duplicateOf != nil || c.direction != t.direction || abs(c.amount - t.amount) >= 0.01 { continue }
            if c.isPrimary && t.isPrimary { continue }
            let gap = abs(c.date.timeIntervalSince(t.date))
            let bankSide = (c.source == .sms && t.source == .sms)
            let window: TimeInterval = bankSide ? 36 * 3600 : 2 * 3600
            if gap > window { continue }
            if let a = c.last4, let b = t.last4, a != b { continue }
            if best == nil || gap < best!.gap { best = (j, gap) }
        }
        if let b = best {
            merge(newer: &t, existingAt: b.index)
            return true
        }
        return false
    }

    /// Keeps the primary record visible and the other one as its duplicate, carrying over what is useful.
    private mutating func merge(newer t: inout Txn, existingAt j: Int) {
        var c = state.txns[j]
        let newIsPrimary = t.isPrimary && !c.isPrimary
        if newIsPrimary {
            c.duplicateOf = t.id
            if c.categorySource == .user { t.category = c.category; t.categorySource = .user }
            enrich(&t, from: c)
            state.txns[j] = c
        } else {
            t.duplicateOf = c.id
            enrich(&c, from: t)
            state.txns[j] = c
        }
    }

    /// A notification or e-mail often names the payee where the bank SMS shows only a UPI ID.
    private func enrich(_ primary: inout Txn, from other: Txn) {
        let weak = primary.counterparty.isEmpty || primary.counterparty.contains("@") || primary.counterparty.hasPrefix("*")
        if weak, !other.counterparty.isEmpty, !other.counterparty.contains("@") {
            primary.counterparty = other.counterparty
        }
        if primary.vpa == nil { primary.vpa = other.vpa }
        if primary.ref == nil { primary.ref = other.ref }
    }

    // MARK: Categories

    /// Sets a category by hand; `remember` makes a rule for this payee and applies it to the others.
    mutating func setCategory(_ id: String, category: String, remember: Bool, label: String?) {
        guard let i = state.txns.firstIndex(where: { $0.id == id }) else { return }
        state.txns[i].category = category
        state.txns[i].categorySource = .user
        state.txns[i].suggestion = nil
        state.txns[i].suggestionNote = nil
        if let l = label?.trimmed, !l.isEmpty { state.txns[i].counterparty = l }
        let key = state.txns[i].counterpartyKey
        if remember && !key.isEmpty {
            state.rules[key] = Rule(key: key, category: category, label: label?.trimmed ?? state.txns[i].counterparty)
            recategorize(onlyUnsorted: false)
        }
    }

    mutating func removeRule(_ key: String) {
        state.rules[key] = nil
        recategorize(onlyUnsorted: false)
    }

    /// Runs the categoriser again. Never touches your own choices, nor web / Claude answers unless a rule now applies.
    mutating func recategorize(onlyUnsorted: Bool) {
        let c = makeCategorizer()
        for i in state.txns.indices {
            let t = state.txns[i]
            if t.categorySource == .user { continue }
            if onlyUnsorted && t.category != Category.uncategorized { continue }
            if t.categorySource == .web || t.categorySource == .claude {
                guard state.rules[t.counterpartyKey] != nil else { continue }
            }
            var copy = t
            apply(c.categorize(copy, hint: copy.hint), to: &copy)
            state.txns[i] = copy
        }
    }

    /// Answer of a web lookup or Claude for one payee key.
    mutating func applyLookup(key: String, category: String?, confident: Bool, note: String?, source: CategorySource, person: Bool, name: String?) {
        for i in state.txns.indices where state.txns[i].counterpartyKey == key {
            var t = state.txns[i]
            guard t.categorySource == .none || t.category == Category.uncategorized else { continue }
            t.lookupState = .done
            if person {
                t.isPerson = true
                t.suggestion = Category.people
            } else if let c = category {
                if confident {
                    t.category = c
                    t.categorySource = source
                    t.suggestion = nil
                } else {
                    t.suggestion = c
                }
            }
            if let n = name, !n.isEmpty, t.counterparty.isEmpty || t.counterparty.uppercased() == t.counterparty { t.counterparty = n }
            t.suggestionNote = note
            state.txns[i] = t
        }
    }

    mutating func markLookup(key: String, state newState: LookupState) {
        for i in state.txns.indices where state.txns[i].counterpartyKey == key && state.txns[i].lookupState == .pending {
            state.txns[i].lookupState = newState
        }
    }

    var uncategorized: [Txn] {
        state.txns.filter { !$0.isDuplicate && !$0.excluded && $0.direction == .debit && $0.category == Category.uncategorized }
            .sorted { $0.date > $1.date }
    }

    // MARK: Balances

    mutating func updateBalance(institution: String, last4: String?, kind: AccountKind, amount: Double, asOf: Date) {
        let id = kind == .broker ? "broker|\(institution)" : "\(institution)|\(last4 ?? "-")"
        var b = state.balances[id] ?? AccountBalance(id: id, institution: institution, last4: last4, kind: kind, balance: amount, asOf: asOf)
        if !b.history.contains(where: { abs($0.date.timeIntervalSince(asOf)) < 60 && abs($0.balance - amount) < 0.01 }) {
            b.history.append(BalancePoint(date: asOf, balance: amount))
            b.history.sort { $0.date < $1.date }
            if b.history.count > 400 { b.history.removeFirst(b.history.count - 400) }
        }
        if asOf >= b.asOf || state.balances[id] == nil {
            b.balance = amount
            b.asOf = asOf
        }
        state.balances[id] = b
    }

    // MARK: Trading

    mutating func upsertTrade(_ d: TradeDay) {
        state.trades[d.id] = d
    }

    func trades(inMonth month: Date) -> [TradeDay] {
        state.trades.values.filter { Cal.sameMonth($0.date, month) }.sorted { $0.date < $1.date }
    }

    /// Trading days with exchange turnover but no P&L recorded.
    func missingTradeDays(inMonth month: Date) -> [Date] {
        let recorded = Set(state.trades.values.map { Cal.dayKey($0.date) })
        let days = Set(state.turnovers.values.filter { Cal.sameMonth($0.date, month) }.map { Cal.dayKey($0.date) })
        return days.subtracting(recorded).compactMap { Cal.fromDayKey($0) }.sorted()
    }

    // MARK: Net worth

    struct NetWorth {
        var bank: Double
        var broker: Double
        var assets: Double
        var liabilities: Double
        var net: Double { bank + broker + assets - liabilities }
        var totalAssets: Double { bank + broker + assets }
    }

    func netWorth() -> NetWorth {
        let bank = state.balances.values.filter { $0.kind == .savings && $0.includeInNetWorth }.reduce(0) { $0 + $1.balance }
        let broker = state.balances.values.filter { $0.kind == .broker && $0.includeInNetWorth }.reduce(0) { $0 + $1.balance }
        let assets = state.manual.filter { !$0.kind.isLiability }.reduce(0) { $0 + $1.value }
        let cardsAuto = state.balances.values.filter { ($0.kind == .creditCard || $0.kind == .loan) && $0.includeInNetWorth }
            .reduce(0) { $0 + abs($1.balance) }
        let liabilities = state.manual.filter { $0.kind.isLiability }.reduce(0) { $0 + $1.value } + cardsAuto
        return NetWorth(bank: bank, broker: broker, assets: assets, liabilities: liabilities)
    }

    /// One snapshot per month, taken on the first day the app runs in that month.
    mutating func snapshotIfNeeded(now: Date = Date()) {
        let month = Cal.startOfMonth(now)
        if state.snapshots.contains(where: { Cal.sameMonth($0.date, month) }) { return }
        let nw = netWorth()
        if nw.totalAssets == 0 && nw.liabilities == 0 { return }
        state.snapshots.append(NetWorthSnapshot(date: month, assets: nw.totalAssets, liabilities: nw.liabilities))
        state.snapshots.sort { $0.date < $1.date }
    }
}
