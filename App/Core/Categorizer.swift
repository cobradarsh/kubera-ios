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
    /// Aliases of 6 characters or more with the spaces taken out ("bajajfinance"), longest first.
    private var compactAliases: [(alias: String, entry: Entry)] = []
    private var vpaTokens: [(token: String, entry: Entry)] = []
    private var vpaExact: [String: Entry] = [:]
    private var byName: [String: Entry] = [:]

    init(entries: [Entry]) {
        self.entries = entries
        for e in entries {
            if byName[e.n] == nil { byName[e.n] = e }
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
        for (a, e) in aliases where a.count >= 6 {
            compactAliases.append((a.replacingOccurrences(of: " ", with: ""), e))
        }
        compactAliases.sort { $0.alias.count > $1.alias.count }
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
                for (t, e) in vpaTokens where MerchantDB.token(t, fits: local) { return e }
            }
        }
        if let n = name {
            let normalized = MerchantDB.normalize(n)
            if !normalized.isEmpty {
                let padded = " " + normalized + " "
                for (a, e) in aliases where padded.contains(" " + a + " ") { return e }
                // Names written as one word ("BAJAJFINANCE", "ZERODHABROKINGLIMITED"). The alias must be whole words of
                // the name run together, so "KINGSTON" is not "gst on" and "PRAMOD MARTIN" is not DMart.
                let runs = MerchantDB.joinedRuns(normalized)
                for (a, e) in compactAliases where runs.contains(a) { return e }
            }
        }
        return nil
    }

    /// The entry shown under this display name ("Credit card bill").
    func entry(named name: String) -> Entry? { byName[name] }

    private static let gluedSuffixes = ["limited", "private", "india", "ltd", "pvt", "llp", "inc"]

    /// Runs of up to six whole words joined without spaces, also with legal words glued on at the end taken off
    /// ("zerodhabrokinglimited" -> "zerodhabroking").
    private static func joinedRuns(_ normalized: String) -> Set<String> {
        let words = normalized.split(separator: " ").map(String.init)
        var out = Set<String>()
        for i in words.indices {
            var run = ""
            for j in i..<min(words.count, i + 6) {
                run += words[j]
                var r = run
                out.insert(r)
                while let s = gluedSuffixes.first(where: { r.count > $0.count + 3 && r.hasSuffix($0) }) {
                    r.removeLast(s.count)
                    out.insert(r)
                }
            }
        }
        return out
    }

    /// A short UPI token must start the ID or follow a non-letter: "uber" fits "uber.rides", not "kuber.k".
    private static func token(_ t: String, fits local: String) -> Bool {
        if t.count >= 6 { return local.contains(t) }
        var from = local.startIndex
        while let r = local.range(of: t, range: from..<local.endIndex) {
            if r.lowerBound == local.startIndex || !local[local.index(before: r.lowerBound)].isLetter { return true }
            from = local.index(after: r.lowerBound)
        }
        return false
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
/// interest), your rules, the merchant list and bank mandate notices, earlier payments to the same (masked) UPI ID,
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

        // The payee as the message named it. `counterparty` may show a merchant's, rule's or notice's name by now, and
        // sorting by that name gives other answers ("Simpl Grocery" has the lender "simpl"). A name key keeps the original.
        let fromKey = t.counterpartyKey.hasPrefix("name:")
        let payee = fromKey ? String(t.counterpartyKey.dropFirst(5)) : t.counterparty

        // 3. Merchant list: UPI ID, then name. A UPI ID key keeps no name, so a payment the list sorted before is
        // known by the list's own name.
        var merchant = db.match(name: nil, vpa: t.vpa)
        if merchant == nil, !fromKey, t.categorySource == .merchant { merchant = db.entry(named: t.counterparty) }
        if merchant == nil { merchant = db.match(name: payee, vpa: nil) ?? db.match(name: nil, vpa: resolved) }

        // 4. Bank mandate notices ("Rs.614 will be deducted on 11/08 For AutoPay … Electricity Bill"), only for debits
        // made under a mandate, nearest notice first. A notice does not rename another merchant, only the bill network
        // its text names ("AutoPay Bharat Connect Electricity Bill").
        if t.direction == .debit, let m = mandateNotice(for: t), let c = m.category,
           merchant == nil || db.match(name: m.purpose, vpa: nil) == merchant {
            return Categorization(category: c, source: .hint, displayName: mandateName(m.purpose))
        }

        if let e = merchant {
            var cat = e.c
            if t.direction == .credit, (categoryKinds[cat] ?? .expense) == .expense {
                // Money back from a shop. A lender's credit is a loan paid out and an insurer's is a payout.
                if hint == .refund { cat = Category.refunds }
                else if cat == "emi" { cat = Category.transfers }
                else if cat == "insurance" { cat = Category.income }
                else { cat = Category.refunds }
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

        // 6. Words in a business's name ("SRI SAI KIRANA" is a shop), then a person, then perhaps a web lookup.
        if let c = Categorizer.keywordCategory(payee) {
            return Categorization(category: c, source: .heuristic, displayName: nil)
        }
        if Categorizer.looksLikePerson(name: payee, vpa: t.vpa) {
            return Categorization(category: Category.uncategorized, source: .none, displayName: nil, isPerson: true, suggestion: Category.people)
        }
        // A lookup sends the name shown, so it has to pass too.
        let lookupable = Categorizer.isLookupable(name: payee, vpa: t.vpa) && Categorizer.isLookupable(name: t.counterparty, vpa: t.vpa)
        return Categorization(category: Category.uncategorized, source: .none, displayName: nil, wantsLookup: lookupable)
    }

    /// The nearest notice of the same amount within three days, for a debit made under a mandate.
    private func mandateNotice(for t: Txn) -> MandateHint? {
        guard !mandates.isEmpty, Categorizer.isMandateDebit(t) else { return nil }
        var best: MandateHint?
        var bestGap = Double.infinity
        for m in mandates where m.category != nil && abs(m.amount - t.amount) < 0.01 {
            let gap = abs(m.due.timeIntervalSince(t.date))
            if gap <= 3 * 86400 && gap < bestGap {
                best = m
                bestGap = gap
            }
        }
        return best
    }

    /// UPI AutoPay, NACH / ACH and card e-mandate debits say so ("UPI Mandate:", "ACH D-", "UMRN", "AutoPay").
    private static let mandateWords = Rx(#"\b(mandate|autopay|auto pay|auto-pay|auto debit|auto-debit|nach|ach|ecs|umrn)\b"#)

    static func isMandateDebit(_ t: Txn) -> Bool {
        t.pattern == "upi-mandate" || t.pattern == "autopay-success" || mandateWords.test(t.raw)
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
        "chats", "chaat", "upahara", "tiffin", "mess", "canteen", "autopay", "bill", "bills",
        "online", "digital", "media", "network", "systems", "global", "international", "ventures", "associates", "consultancy",
        "station", "parking", "toll", "metro", "airlines", "airways", "infotech", "infra", "pay", "upi",
    ]

    private static let personTitles: Set<String> = ["mr", "mrs", "ms", "smt", "shri", "kum", "mohd", "md", "dr"]

    /// UPI IDs used by shops' QR codes and payment gateways, not people.
    private static let merchantVPAMarkers = [
        "paytm.", "paytm-", "paytmqr", "gpay-", "bharatpe", ".rzp", "rzp.", ".bqr", ".payu", "payu", "ecom", "upi", "store", "shop", "mart",
        "merchant", "razorpay", "cashfree", "billdesk", "phonepe.", "mswipe", "pinelabs", "ezetap", "yespay", "ibz", "q0", "bqr",
    ]
    /// Handles only businesses get (people's IDs end in @apl, @pnb, @ikwik, @paytm, @okaxis and so on).
    private static let merchantHandles = ["okbizaxis", "okbizaxi", "okbizicici", "ptys", "pty", "rapl", "axb", "rzp"]

    /// "9876543210", "919876543210", "9876543210-2": an ID made from a phone number.
    private static func isPhoneNumber(_ local: String) -> Bool {
        if local.filter({ $0.isNumber }).count == 10 && local.count <= 12 { return true }
        return local.range(of: #"^(91)?[0-9]{10}([-._]?[0-9]{1,2})?$"#, options: .regularExpression) != nil
    }

    static func looksLikePerson(name: String?, vpa: String?) -> Bool {
        if let v = vpa?.lowercased(), v.contains("@") {
            let parts = v.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let local = parts[0]
            let handle = parts.count > 1 ? parts[1] : ""
            // A masked ID ("*esh@okaxis") says nothing either way.
            if !local.hasPrefix("*") {
                if isPhoneNumber(local) { return true }
                if merchantVPAMarkers.contains(where: { local.contains($0) }) { return false }
                if merchantHandles.contains(handle) { return false }
                if local.range(of: #"^q\d{6,}"#, options: .regularExpression) != nil { return false } // PhonePe merchant QR
                // "rahul123@okicici", "anita.k2@okicici": letters, optional dots and digits.
                if local.range(of: #"^[a-z][a-z.]{2,}[0-9]{0,6}$"#, options: .regularExpression) != nil
                    || local.range(of: #"^[a-z]+[0-9]{1,4}[a-z]+[0-9]*$"#, options: .regularExpression) != nil { return true }
            }
            // The ID does not settle it ("rk1990@", "ramesh_k@oksbi"): the name does, unless the name is the ID itself.
            if name?.contains("@") ?? true { return false }
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

    /// Whether a payee's name may go to a web lookup or Claude: a business's name, never a person's.
    static func isLookupable(name: String?, vpa: String?) -> Bool {
        guard let n = name?.trimmed, n.count >= 3 else { return false }
        if n.contains("@") { return false }                  // a UPI ID tells the web nothing
        if n.filter({ $0.isLetter }).count < 3 { return false }
        // Judged on the words a search sends: words with digits are left out of it.
        let words = MerchantDB.normalize(n).split(separator: " ").map(String.init).filter { w in !w.contains(where: { $0.isNumber }) }
        guard let first = words.first else { return false }
        // One plain word ("MANJUNATHA", "Amma") is as likely a person's name as a shop's.
        if words.count == 1 && !businessWords.contains(first) { return false }
        // A UPI ID can show that a payee is a person, never that a named one is not.
        if looksLikePerson(name: words.joined(separator: " "), vpa: nil) { return false }
        if let v = vpa, looksLikePerson(name: nil, vpa: v) { return false }
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
        // A card bill paid from the bank moves money; the card's purchases are the spending.
        (Category.transfers, ["credit card", "card bill", "cc bill"]),
        ("emi", ["finance", "financial services", "capital", "loan", "loans"]),
        ("entertainment", ["cinemas", "cinema", "theatre", "theater", "multiplex", "gaming", "games", "amusement", "bowling"]),
    ]
    /// Loose words: they decide only when no other word does ("METRO SHOES" is a shoe shop, "SAI MOBILE STORE" a phone shop).
    private static let looseKeywords: Set<String> = ["store", "stores", "mart", "general store", "general stores", "fresh", "metro", "power", "capital", "hotel"]
    /// Keywords that are also people's names: they count only beside a business word ("SAGAR PATIL" is a person).
    private static let nameKeywords: Set<String> = ["sagar", "darshini", "bhavan", "vidya", "seva", "beauty", "yoga"]

    static func keywordCategory(_ name: String?) -> String? {
        guard let n = name else { return nil }
        let normalized = MerchantDB.normalize(n)
        let padded = " " + normalized + " "
        func hit(_ use: (String) -> Bool) -> String? {
            for (category, list) in keywordTable {
                for w in list where use(w) && padded.contains(" " + w + " ") { return category }
            }
            return nil
        }
        if let c = hit({ !looseKeywords.contains($0) && !nameKeywords.contains($0) }) { return c }
        if let c = hit({ looseKeywords.contains($0) }) { return c }
        let words = normalized.split(separator: " ").map(String.init)
        guard words.contains(where: { businessWords.contains($0) }) else { return nil }
        return hit({ nameKeywords.contains($0) })
    }
}
