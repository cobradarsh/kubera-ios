import Foundation

/// The built-in merchant list (`Resources/merchants.json`): names, legal names, card descriptors and UPI IDs.
final class MerchantDB {
    struct Entry: Codable, Hashable {
        let n: String          // display name
        let c: String          // category id
        let a: [String]?       // name aliases (matched as whole words in the normalised payee name)
        let v: [String]?       // UPI: "token" = part of the ID before "@", "local@handle" = exact ID
    }
    struct File: Codable {
        let version: Int
        let merchants: [Entry]
    }

    let entries: [Entry]
    private var aliases: [(alias: String, entry: Entry)] = []
    private var vpaTokens: [(token: String, entry: Entry)] = []
    private var vpaExact: [String: Entry] = [:]

    init(entries: [Entry]) {
        self.entries = entries
        for e in entries {
            for a in e.a ?? [] {
                let n = MerchantDB.normalize(a)
                if !n.isEmpty { aliases.append((n, e)) }
            }
            for v in e.v ?? [] {
                let l = v.lowercased()
                if l.contains("@") {
                    vpaExact[l] = e
                    // HDFC masks a payee's UPI ID to its last four characters: "upiswiggy@icici" -> "*iggy@icici".
                    let parts = l.split(separator: "@", maxSplits: 1).map(String.init)
                    if parts.count == 2, !parts[0].hasPrefix("*"), parts[0].count > 4 {
                        let masked = "*" + parts[0].suffix(4) + "@" + parts[1]
                        if vpaExact[masked] == nil { vpaExact[masked] = e }
                    }
                } else if l.count >= 4 {
                    vpaTokens.append((l, e))
                }
            }
        }
        aliases.sort { $0.alias.count > $1.alias.count }
        vpaTokens.sort { $0.token.count > $1.token.count }
    }

    convenience init(data: Data) throws {
        let f = try JSONDecoder().decode(File.self, from: data)
        self.init(entries: f.merchants)
    }

    static func load() -> MerchantDB {
        if let url = Bundle.main.url(forResource: "merchants", withExtension: "json"),
           let d = try? Data(contentsOf: url), let db = try? MerchantDB(data: d) {
            return db
        }
        return MerchantDB(entries: [])
    }

    /// Lowercase, everything that is not a letter or digit becomes a space, runs collapsed.
    static func normalize(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var space = true
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                space = false
            } else if !space {
                out.append(" ")
                space = true
            }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    func match(name: String?, vpa: String?) -> Entry? {
        if let v = vpa?.lowercased(), !v.isEmpty {
            if let e = vpaExact[v] { return e }
            let local = v.split(separator: "@").first.map(String.init) ?? v
            if !local.hasPrefix("*") {
                for (t, e) in vpaTokens where local.contains(t) { return e }
            }
        }
        if let n = name {
            let padded = " " + MerchantDB.normalize(n) + " "
            if padded.count > 2 {
                for (a, e) in aliases where padded.contains(" " + a + " ") { return e }
                // Bank SMS cut payee names at 25 characters: "AutoPay Bharat Connec", "Google India Digital Serv".
                let compact = padded.replacingOccurrences(of: " ", with: "")
                if compact.count >= 6 {
                    for (a, e) in aliases where a.count >= 6 && compact.contains(a.replacingOccurrences(of: " ", with: "")) { return e }
                }
            }
        }
        return nil
    }
}

struct Categorization {
    var category: String
    var source: CategorySource
    var displayName: String?
    var isPerson: Bool = false
    var suggestion: String?
    /// Worth a web lookup (an unknown business).
    var wantsLookup: Bool = false
}

/// Decides a transaction's category without the network. Order: system hints (transfers, investments, cash,
/// interest), your rules, bank mandate notices, the merchant list, earlier payments to the same (masked) UPI ID,
/// words in the payee's name; a person is left for the check-in with "People" suggested.
struct Categorizer {
    var db: MerchantDB
    var rules: [String: Rule]
    /// Full UPI ID (lowercased) -> (category, name) learned from categorised payments.
    var knownVPAs: [String: (category: String, name: String?)]
    var mandates: [MandateHint]
    var categoryKinds: [String: CategoryKind]

    static func key(counterparty: String?, vpa: String?) -> String {
        if let v = vpa?.lowercased(), !v.isEmpty { return "vpa:" + v }
        let n = MerchantDB.normalize(counterparty ?? "")
        return n.isEmpty ? "" : "name:" + n
    }

    func categorize(_ t: Txn, hint: TxnHint) -> Categorization {
        // 1. System hints.
        switch hint {
        case .brokerFunding where t.direction == .debit, .brokerPayout where t.direction == .credit:
            return Categorization(category: Category.investments, source: .system, displayName: brokerDisplay(t.counterparty))
        case .cardBillPaid: return Categorization(category: Category.transfers, source: .system, displayName: "Credit card bill paid")
        case .cashDeposit: return Categorization(category: Category.transfers, source: .system, displayName: "Cash deposit")
        case .selfTransfer: return Categorization(category: Category.transfers, source: .system, displayName: t.counterparty)
        case .interest: return Categorization(category: Category.income, source: .system, displayName: "Interest")
        case .salary: return Categorization(category: Category.income, source: .system, displayName: "Salary")
        case .atm where t.direction == .debit: return Categorization(category: "cash", source: .system, displayName: "Cash withdrawal")
        default: break
        }

        // 2. Your rules (exact key, then the resolved key of a masked UPI ID).
        let k = t.counterpartyKey
        if !k.isEmpty, let r = rules[k] {
            return Categorization(category: r.category, source: .rule, displayName: r.label.isEmpty ? nil : r.label)
        }
        let resolved = resolveMasked(t.vpa)
        if let full = resolved, let r = rules["vpa:" + full] {
            return Categorization(category: r.category, source: .rule, displayName: r.label.isEmpty ? nil : r.label)
        }

        // 3. Bank mandate notices ("Rs.614 will be deducted on 11/08 For AutoPay … Electricity Bill").
        if t.direction == .debit {
            for m in mandates {
                guard let c = m.category, abs(m.amount - t.amount) < 0.01 else { continue }
                if abs(m.due.timeIntervalSince(t.date)) <= 3 * 86400 {
                    return Categorization(category: c, source: .hint, displayName: mandateName(m.purpose))
                }
            }
        }

        // 4. Merchant list.
        if let e = db.match(name: t.counterparty, vpa: t.vpa) ?? db.match(name: nil, vpa: resolved) {
            var cat = e.c
            if t.direction == .credit {
                let kind = categoryKinds[cat] ?? .expense
                if kind == .expense { cat = Category.refunds }
            }
            return Categorization(category: cat, source: .merchant, displayName: e.n)
        }

        // 5. Earlier payments to the same UPI ID (HDFC masks it to "*abcd@pty" on credit card UPI alerts).
        if let full = resolved, let known = knownVPAs[full] {
            return Categorization(category: known.category, source: .history, displayName: known.name)
        }

        // Credits that nothing above recognised: money received.
        if t.direction == .credit {
            if hint == .refund { return Categorization(category: Category.refunds, source: .system, displayName: t.counterparty) }
            return Categorization(category: Category.income, source: .system, displayName: nil)
        }

        // 6. A person, or words in a business's name.
        let person = Categorizer.looksLikePerson(name: t.counterparty, vpa: t.vpa)
        if person {
            return Categorization(category: Category.uncategorized, source: .none, displayName: nil, isPerson: true, suggestion: Category.people)
        }
        if let c = Categorizer.keywordCategory(t.counterparty) {
            return Categorization(category: c, source: .heuristic, displayName: nil)
        }
        let lookupable = Categorizer.isLookupable(name: t.counterparty, vpa: t.vpa)
        return Categorization(category: Category.uncategorized, source: .none, displayName: nil, wantsLookup: lookupable)
    }

    /// "*iggy@icici" -> "upiswiggy@icici" when exactly one known UPI ID ends that way.
    func resolveMasked(_ vpa: String?) -> String? {
        guard let v = vpa?.lowercased(), v.hasPrefix("*"), v.count > 3 else { return nil }
        let tail = String(v.dropFirst())
        var hit: String?
        for full in knownVPAs.keys where !full.hasPrefix("*") && full.hasSuffix(tail) {
            if hit != nil && hit != full { return nil }
            hit = full
        }
        return hit
    }

    private func brokerDisplay(_ name: String?) -> String? {
        guard let n = name else { return nil }
        return MessageParser.isBroker(n) ? MessageParser.brokerName(n) : n
    }

    private func mandateName(_ purpose: String) -> String {
        var p = purpose
        for prefix in ["AutoPay Bharat Connect ", "AutoPay "] where p.hasPrefix(prefix) { p = String(p.dropFirst(prefix.count)) }
        return p.replacingOccurrences(of: " Payment", with: "")
    }

    // MARK: Names

    static let businessWords: Set<String> = [
        "store", "stores", "mart", "medical", "medicals", "pharma", "pharmacy", "chemist", "chemists", "hotel", "hotels", "restaurant",
        "cafe", "bakery", "bakers", "sweets", "foods", "food", "kitchen", "dhaba", "biryani", "handi", "enterprises", "enterprise",
        "traders", "trading", "agency", "agencies", "services", "service", "serv", "solutions", "technologies", "tech", "pvt", "private",
        "ltd", "limited", "llp", "inc", "india", "co", "company", "corp", "corporation", "industries", "electricals", "electronics",
        "electric", "motors", "automobiles", "garage", "hospital", "clinic", "diagnostics", "diagnostic", "labs", "lab", "dental",
        "care", "health", "healthcare", "center", "centre", "school", "college", "academy", "institute", "classes", "tuition",
        "travels", "tours", "salon", "spa", "parlour", "studio", "fitness", "gym", "fashion", "fashions", "garments", "textiles",
        "silks", "jewellers", "jewellery", "footwear", "opticals", "optical", "mobile", "mobiles", "telecom", "communications",
        "fibernet", "broadband", "finance", "financial", "bank", "capital", "securities", "insurance", "trust", "foundation",
        "temple", "society", "association", "club", "petroleum", "fuel", "petrol", "gas", "water", "power", "milk", "dairy",
        "provision", "provisions", "general", "super", "supermarket", "hypermarket", "bazaar", "bazar", "shop", "shoppe",
        "world", "point", "hub", "plaza", "mall", "cinemas", "theatre", "escrow", "payments", "wallet", "retail", "wholesale",
        "distributors", "exports", "logistics", "courier", "cabs", "taxi", "fruits", "vegetables", "chicken", "mutton", "meat",
        "fish", "juice", "tea", "coffee", "bar", "pub", "brewery", "wines", "ayurveda", "books", "stationery", "xerox", "printers",
        "hardware", "paints", "constructions", "builders", "developers", "properties", "realty", "estates", "rentals", "lodge",
        "residency", "inn", "resort", "hostel", "toys", "gifts", "flowers", "cakes", "icecream", "creamery", "pizza", "burger",
        "chats", "chaat", "bhavan", "darshini", "sagar", "upahara", "tiffin", "mess", "canteen", "autopay", "bill", "bills",
        "online", "digital", "media", "network", "systems", "global", "international", "ventures", "associates", "consultancy",
        "station", "parking", "toll", "metro", "airlines", "airways", "infotech", "infra", "pay", "upi",
    ]

    private static let personTitles: Set<String> = ["mr", "mrs", "ms", "smt", "shri", "kum", "mohd", "md", "dr"]

    /// UPI IDs used by shops' QR codes and payment gateways, not people.
    private static let merchantVPAMarkers = [
        "paytm.", "paytmqr", "gpay-", "bharatpe", ".rzp", "rzp.", ".bqr", ".payu", "payu", "ecom", "upi", "store", "shop", "mart",
        "merchant", "razorpay", "cashfree", "billdesk", "phonepe.", "mswipe", "pinelabs", "ezetap", "yespay", "ibz", "q0", "bqr",
    ]
    private static let merchantHandles = ["okbizaxis", "okbizaxi", "okbizicici", "ptys", "pty", "paytm", "rapl", "apl", "axb", "rzp", "pnb", "ikwik"]

    static func looksLikePerson(name: String?, vpa: String?) -> Bool {
        if let v = vpa?.lowercased(), v.contains("@") {
            let parts = v.split(separator: "@", maxSplits: 1).map(String.init)
            let local = parts[0]
            let handle = parts.count > 1 ? parts[1] : ""
            if local.hasPrefix("*") { return false }      // masked: unknown
            if local.filter({ $0.isNumber }).count == 10 && local.count <= 12 { return true } // phone number
            if merchantVPAMarkers.contains(where: { local.contains($0) }) { return false }
            if merchantHandles.contains(handle) { return false }
            if local.range(of: #"^q\d{6,}"#, options: .regularExpression) != nil { return false } // PhonePe merchant QR
            // "rahul123@okicici", "anita.k2@okicici": letters, optional dots and digits.
            return local.range(of: #"^[a-z][a-z.]{2,}[0-9]{0,6}$"#, options: .regularExpression) != nil
                || local.range(of: #"^[a-z]+[0-9]{1,4}[a-z]+[0-9]*$"#, options: .regularExpression) != nil
        }
        guard let n = name?.trimmed, !n.isEmpty else { return false }
        let words = MerchantDB.normalize(n).split(separator: " ").map(String.init)
        guard !words.isEmpty, words.count <= 5 else { return false }
        if words.contains(where: { businessWords.contains($0) }) { return false }
        if words.contains(where: { $0.contains(where: { $0.isNumber }) }) { return false }
        if words.contains(where: { personTitles.contains($0) }) { return true }
        // Two or more plain words ("RAHUL K", "MOHD ARIF", "SURESH RAMESH RAO").
        return words.count >= 2
    }

    static func isLookupable(name: String?, vpa: String?) -> Bool {
        guard let n = name?.trimmed, n.count >= 3 else { return false }
        if n.contains("@") { return false }                  // a UPI ID tells the web nothing
        if n.filter({ $0.isLetter }).count < 3 { return false }
        return true
    }

    private static let keywordTable: [(String, [String])] = [
        ("health", ["medical", "medicals", "pharma", "pharmacy", "chemist", "chemists", "hospital", "hospitals", "clinic", "diagnostic", "diagnostics", "labs", "dental", "ayurveda", "homeo", "healthcare", "health care", "physio", "opticals", "optical", "medicines"]),
        ("food", ["hotel", "restaurant", "restaurants", "cafe", "bakery", "bakers", "sweets", "foods", "kitchen", "dhaba", "biryani", "handi", "pizza", "burger", "chats", "chaat", "bhavan", "darshini", "sagar", "upahara", "tiffin", "tiffins", "mess", "canteen", "juice", "juices", "tea", "coffee", "icecream", "ice cream", "creamery", "cakes", "bar", "pub", "brewery", "brewing", "dosa", "idli", "grill", "kebab", "momos", "chai", "eatery", "eats", "food court"]),
        ("groceries", ["mart", "supermarket", "super market", "hypermarket", "provision", "provisions", "kirana", "general store", "general stores", "stores", "store", "fruits", "vegetables", "dairy", "milk", "chicken", "mutton", "meat", "fish", "departmental", "fresh"]),
        ("fuel", ["petroleum", "fuel", "fuels", "petrol", "filling station", "service station", "fuel station"]),
        ("travel", ["travels", "tours", "holidays", "resort", "resorts", "lodge", "residency", "inn", "hostel", "airlines", "airways", "railway"]),
        ("transport", ["cabs", "taxi", "parking", "toll", "metro", "fastag", "car wash", "tyres"]),
        ("personal", ["salon", "spa", "parlour", "parlor", "beauty", "barber", "fitness", "gym", "yoga", "unisex"]),
        ("education", ["school", "college", "academy", "institute", "classes", "tuition", "university", "coaching", "vidyalaya", "vidya"]),
        ("donations", ["temple", "trust", "foundation", "mutt", "math", "church", "masjid", "seva", "charity", "devasthana", "devasthanam", "gurudwara"]),
        ("bills", ["electricity", "water supply", "broadband", "fibernet", "telecom", "recharge", "dth", "power"]),
        ("home", ["rentals", "properties", "realty", "estates", "builders", "developers", "constructions", "interiors", "furniture", "furnishing", "plywood", "maintenance", "apartment", "apartments", "owners association", "welfare association"]),
        ("shopping", ["fashion", "fashions", "garments", "textiles", "silks", "sarees", "jewellers", "jewellery", "jewelry", "footwear", "shoes", "electronics", "electricals", "mobiles", "mobile", "hardware", "paints", "stationery", "books", "gifts", "toys", "boutique", "collections", "watches", "lifestyle"]),
        ("insurance", ["insurance", "assurance"]),
        ("emi", ["finance", "financial services", "capital", "loan", "loans", "credit"]),
        ("entertainment", ["cinemas", "cinema", "theatre", "theater", "multiplex", "gaming", "games", "amusement", "bowling"]),
    ]

    static func keywordCategory(_ name: String?) -> String? {
        guard let n = name else { return nil }
        let padded = " " + MerchantDB.normalize(n) + " "
        for (cat, words) in keywordTable {
            for w in words where padded.contains(" " + w + " ") { return cat }
        }
        return nil
    }
}
