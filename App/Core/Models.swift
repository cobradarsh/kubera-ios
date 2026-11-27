import Foundation

// MARK: - Transactions

enum TxnDirection: String, Codable { case debit, credit }

enum TxnSource: String, Codable, CaseIterable {
    case sms, notification, email, manual
    var label: String {
        switch self {
        case .sms: return "SMS"
        case .notification: return "Notification"
        case .email: return "Email"
        case .manual: return "Added by you"
        }
    }
}

enum Instrument: String, Codable, CaseIterable {
    case upi, account, debitCard, creditCard, creditCardUPI, netbanking, wallet, cash, unknown
    var label: String {
        switch self {
        case .upi: return "UPI"
        case .account: return "Bank account"
        case .debitCard: return "Debit card"
        case .creditCard: return "Credit card"
        case .creditCardUPI: return "Credit card (UPI)"
        case .netbanking: return "Net banking"
        case .wallet: return "Wallet"
        case .cash: return "Cash"
        case .unknown: return "Other"
        }
    }
    var symbol: String {
        switch self {
        case .upi: return "arrow.left.arrow.right.circle"
        case .account: return "building.columns"
        case .debitCard: return "creditcard"
        case .creditCard, .creditCardUPI: return "creditcard.fill"
        case .netbanking: return "network"
        case .wallet: return "wallet.pass"
        case .cash: return "banknote"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// Where a transaction's category came from (shown as a small tag; "user" is never overwritten).
enum CategorySource: String, Codable {
    case none, system, rule, merchant, hint, history, heuristic, web, claude, user
    var label: String {
        switch self {
        case .none: return "Not sorted"
        case .system: return "Automatic"
        case .rule: return "Your rule"
        case .merchant: return "Merchant list"
        case .hint: return "Bank notice"
        case .history: return "Earlier payments"
        case .heuristic: return "Name"
        case .web: return "Web lookup"
        case .claude: return "Claude"
        case .user: return "You"
        }
    }
}

struct Txn: Identifiable, Codable, Hashable {
    var id: String
    var date: Date
    var amount: Double
    var direction: TxnDirection
    var category: String = Category.uncategorized
    var categorySource: CategorySource = .none
    /// Shown name: merchant or payee.
    var counterparty: String = ""
    /// Normalised key used by rules ("swiggy limited", "vpa:paytm.s21abcd@pty").
    var counterpartyKey: String = ""
    var vpa: String?
    var instrument: Instrument = .unknown
    var bank: String?
    var last4: String?
    var ref: String?
    var balanceAfter: Double?
    var note: String?
    var raw: String = ""
    var source: TxnSource = .sms
    var sender: String?
    /// Secondary messages (confirmations, notifications, e-mails) that repeat a primary one are kept but hidden.
    var duplicateOf: String?
    var isPrimary: Bool = true
    /// Excluded by the user from all totals.
    var excluded: Bool = false
    /// A person (UPI to an individual) rather than a business.
    var isPerson: Bool = false
    /// Suggested category waiting for confirmation (web lookup / Claude).
    var suggestion: String?
    var suggestionNote: String?
    var lookupState: LookupState = .none
    var hint: TxnHint = .none
    /// Which parser pattern read it (diagnostics).
    var pattern: String?
    var createdAt: Date = Date()

    var isDuplicate: Bool { duplicateOf != nil }
    var signedAmount: Double { direction == .debit ? amount : -amount }

    init(id: String, date: Date, amount: Double, direction: TxnDirection) {
        self.id = id
        self.date = date
        self.amount = amount
        self.direction = direction
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, amount, direction, category, categorySource, counterparty, counterpartyKey, vpa, instrument, bank,
             last4, ref, balanceAfter, note, raw, source, sender, duplicateOf, isPrimary, excluded, isPerson, suggestion,
             suggestionNote, lookupState, hint, pattern, createdAt
    }

    // Every field but the first four may be missing in older files.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        amount = try c.decode(Double.self, forKey: .amount)
        direction = try c.decode(TxnDirection.self, forKey: .direction)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? Category.uncategorized
        categorySource = try c.decodeIfPresent(CategorySource.self, forKey: .categorySource) ?? .none
        counterparty = try c.decodeIfPresent(String.self, forKey: .counterparty) ?? ""
        counterpartyKey = try c.decodeIfPresent(String.self, forKey: .counterpartyKey) ?? ""
        vpa = try c.decodeIfPresent(String.self, forKey: .vpa)
        instrument = try c.decodeIfPresent(Instrument.self, forKey: .instrument) ?? .unknown
        bank = try c.decodeIfPresent(String.self, forKey: .bank)
        last4 = try c.decodeIfPresent(String.self, forKey: .last4)
        ref = try c.decodeIfPresent(String.self, forKey: .ref)
        balanceAfter = try c.decodeIfPresent(Double.self, forKey: .balanceAfter)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        raw = try c.decodeIfPresent(String.self, forKey: .raw) ?? ""
        source = try c.decodeIfPresent(TxnSource.self, forKey: .source) ?? .sms
        sender = try c.decodeIfPresent(String.self, forKey: .sender)
        duplicateOf = try c.decodeIfPresent(String.self, forKey: .duplicateOf)
        isPrimary = try c.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? true
        excluded = try c.decodeIfPresent(Bool.self, forKey: .excluded) ?? false
        isPerson = try c.decodeIfPresent(Bool.self, forKey: .isPerson) ?? false
        suggestion = try c.decodeIfPresent(String.self, forKey: .suggestion)
        suggestionNote = try c.decodeIfPresent(String.self, forKey: .suggestionNote)
        lookupState = try c.decodeIfPresent(LookupState.self, forKey: .lookupState) ?? .none
        hint = try c.decodeIfPresent(TxnHint.self, forKey: .hint) ?? .none
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

enum LookupState: String, Codable { case none, pending, done, failed, skipped }

// MARK: - Categories

enum CategoryKind: String, Codable, CaseIterable {
    case expense, income, transfer, investment
    var label: String {
        switch self {
        case .expense: return "Spending"
        case .income: return "Income"
        case .transfer: return "Transfer (not counted)"
        case .investment: return "Investment (not counted)"
        }
    }
}

struct Category: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var symbol: String
    var colorHex: String
    var kind: CategoryKind
    var builtIn: Bool = true

    static let uncategorized = "uncategorized"
    static let people = "people"
    static let transfers = "transfers"
    static let investments = "investments"
    static let income = "income"
    static let refunds = "refunds"

    static let builtIns: [Category] = [
        Category(id: "food", name: "Food & Dining", symbol: "fork.knife", colorHex: "#FF8A3D", kind: .expense),
        Category(id: "groceries", name: "Groceries", symbol: "cart.fill", colorHex: "#8BC34A", kind: .expense),
        Category(id: "shopping", name: "Shopping", symbol: "bag.fill", colorHex: "#E91E63", kind: .expense),
        Category(id: "transport", name: "Transport", symbol: "car.fill", colorHex: "#29B6F6", kind: .expense),
        Category(id: "fuel", name: "Fuel", symbol: "fuelpump.fill", colorHex: "#FFB300", kind: .expense),
        Category(id: "bills", name: "Bills & Utilities", symbol: "bolt.fill", colorHex: "#FFD54F", kind: .expense),
        Category(id: "home", name: "Home & Rent", symbol: "house.fill", colorHex: "#A1887F", kind: .expense),
        Category(id: "health", name: "Health", symbol: "cross.case.fill", colorHex: "#EF5350", kind: .expense),
        Category(id: "subscriptions", name: "Subscriptions", symbol: "play.rectangle.fill", colorHex: "#AB47BC", kind: .expense),
        Category(id: "entertainment", name: "Entertainment", symbol: "film.fill", colorHex: "#7E57C2", kind: .expense),
        Category(id: "travel", name: "Travel", symbol: "airplane", colorHex: "#26C6DA", kind: .expense),
        Category(id: "education", name: "Education", symbol: "book.fill", colorHex: "#5C6BC0", kind: .expense),
        Category(id: "personal", name: "Personal Care", symbol: "sparkles", colorHex: "#F48FB1", kind: .expense),
        Category(id: "donations", name: "Gifts & Donations", symbol: "gift.fill", colorHex: "#FFCA28", kind: .expense),
        Category(id: "emi", name: "EMI & Loans", symbol: "indianrupeesign.circle.fill", colorHex: "#FF7043", kind: .expense),
        Category(id: "insurance", name: "Insurance", symbol: "shield.fill", colorHex: "#66BB6A", kind: .expense),
        Category(id: "fees", name: "Fees & Charges", symbol: "exclamationmark.circle.fill", colorHex: "#BDBDBD", kind: .expense),
        Category(id: "people", name: "People", symbol: "person.2.fill", colorHex: "#4DB6AC", kind: .expense),
        Category(id: "cash", name: "Cash", symbol: "banknote.fill", colorHex: "#9CCC65", kind: .expense),
        Category(id: "refunds", name: "Refunds & Cashback", symbol: "arrow.uturn.backward.circle.fill", colorHex: "#4FC3F7", kind: .expense),
        Category(id: "uncategorized", name: "Uncategorised", symbol: "questionmark.circle.fill", colorHex: "#757575", kind: .expense),
        Category(id: "income", name: "Income", symbol: "arrow.down.circle.fill", colorHex: "#4CAF50", kind: .income),
        Category(id: "investments", name: "Investments & Trading", symbol: "chart.line.uptrend.xyaxis", colorHex: "#D4AF37", kind: .investment),
        Category(id: "transfers", name: "Transfers", symbol: "arrow.left.arrow.right", colorHex: "#90A4AE", kind: .transfer),
    ]
}

/// "Always put <key> in <category>". Keys are counterparty keys (see `Txn.counterpartyKey`).
struct Rule: Identifiable, Codable, Hashable {
    var id: String { key }
    var key: String
    var category: String
    var label: String
    var created: Date = Date()
    var hits: Int = 0
}

// MARK: - Balances, trading, net worth

enum AccountKind: String, Codable, CaseIterable {
    case savings, creditCard, broker, loan, wallet
    var label: String {
        switch self {
        case .savings: return "Bank account"
        case .creditCard: return "Credit card"
        case .broker: return "Trading account"
        case .loan: return "Loan"
        case .wallet: return "Wallet"
        }
    }
}

/// A balance read from a message ("Available Bal in HDFC Bank A/c XX1234 … is INR …").
struct AccountBalance: Identifiable, Codable, Hashable {
    var id: String            // "HDFC Bank|1234" / "broker|Dhan"
    var institution: String
    var last4: String?
    var kind: AccountKind
    var balance: Double
    var asOf: Date
    var nickname: String?
    var includeInNetWorth: Bool = true
    var history: [BalancePoint] = []

    var title: String {
        if let n = nickname, !n.isEmpty { return n }
        if let l = last4 { return "\(institution) ••\(l)" }
        return institution
    }
}

struct BalancePoint: Codable, Hashable {
    var date: Date
    var balance: Double
}

/// Turnover reported by the exchanges (BSE trade confirmation, NSE "traded value" SMS).
struct Turnover: Codable, Hashable, Identifiable {
    var id: String { "\(exchange)|\(Cal.dayKey(date))|\(segment)" }
    var date: Date
    var exchange: String
    var segment: String
    var value: Double
}

/// E-mandate / AutoPay notices ("Rs.614 will be deducted on 11/08/26 For AutoPay … Electricity Bill").
struct MandateHint: Codable, Hashable {
    var amount: Double
    var due: Date
    var purpose: String
    var category: String?
}

struct PositionPnL: Codable, Hashable, Identifiable {
    var id: String { symbol + "|" + String(pnl) }
    var symbol: String
    var pnl: Double
}

enum TradeSource: String, Codable { case screenshot, manual }

/// One day's result at one broker.
struct TradeDay: Identifiable, Codable, Hashable {
    var id: String            // "2026-11-26|Dhan"
    var date: Date            // start of the trading day (IST)
    var broker: String
    var pnl: Double
    var charges: Double?
    var positions: [PositionPnL] = []
    var note: String?
    var source: TradeSource = .manual
    var assetId: String?      // Photos local identifier of the screenshot
    var addedAt: Date = Date()

    var net: Double { pnl - (charges ?? 0) }
    static func key(_ date: Date, _ broker: String) -> String { Cal.dayKey(date) + "|" + broker }
}

enum AssetKind: String, Codable, CaseIterable, Identifiable {
    case bank, broker, stocks, mutualFunds, fixedDeposit, gold, property, vehicle, providentFund, nps, cash, crypto, receivable, otherAsset
    case creditCard, loan, otherLiability
    var id: String { rawValue }
    var isLiability: Bool { self == .creditCard || self == .loan || self == .otherLiability }
    var label: String {
        switch self {
        case .bank: return "Bank balance"
        case .broker: return "Trading account cash"
        case .stocks: return "Stocks & ETFs"
        case .mutualFunds: return "Mutual funds"
        case .fixedDeposit: return "Fixed deposits"
        case .gold: return "Gold & silver"
        case .property: return "Property"
        case .vehicle: return "Vehicle"
        case .providentFund: return "PF / PPF"
        case .nps: return "NPS"
        case .cash: return "Cash in hand"
        case .crypto: return "Crypto"
        case .receivable: return "Money lent"
        case .otherAsset: return "Other asset"
        case .creditCard: return "Credit card dues"
        case .loan: return "Loan"
        case .otherLiability: return "Other liability"
        }
    }
    var symbol: String {
        switch self {
        case .bank: return "building.columns.fill"
        case .broker: return "chart.bar.fill"
        case .stocks: return "chart.line.uptrend.xyaxis"
        case .mutualFunds: return "chart.pie.fill"
        case .fixedDeposit: return "lock.fill"
        case .gold: return "circle.hexagongrid.fill"
        case .property: return "house.fill"
        case .vehicle: return "car.fill"
        case .providentFund: return "briefcase.fill"
        case .nps: return "person.crop.circle.badge.clock"
        case .cash: return "banknote.fill"
        case .crypto: return "bitcoinsign.circle.fill"
        case .receivable: return "person.fill.checkmark"
        case .otherAsset: return "square.stack.3d.up.fill"
        case .creditCard: return "creditcard.fill"
        case .loan: return "doc.text.fill"
        case .otherLiability: return "minus.circle.fill"
        }
    }
}

/// Something you own or owe, typed in by hand (or updated from a holdings screenshot).
struct ManualItem: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var kind: AssetKind
    var value: Double
    var updated: Date = Date()
    var note: String?
}

struct NetWorthSnapshot: Identifiable, Codable, Hashable {
    var id: String { Cal.dayKey(date) }
    var date: Date
    var assets: Double
    var liabilities: Double
    var net: Double { assets - liabilities }
}

struct Holiday: Identifiable, Codable, Hashable {
    var id: String { Cal.dayKey(date) + "|" + kind.rawValue + "|" + name }
    var date: Date
    var name: String
    var kind: HolidayKind
    var note: String?
}

enum HolidayKind: String, Codable { case nse, india, special }
