import Foundation

/// One message from any source, before parsing.
struct RawMessage {
    var id: String          // "sms:1234", "ntf:<request id>", "mail:<uid>"
    var date: Date
    var sender: String      // SMS handle ("AD-HDFCBK-S(smsft)"), app bundle id, or mail From
    var text: String
    var source: TxnSource
}

/// What a message told us.
enum ParsedItem {
    case txn(ParsedTxn)
    case balance(institution: String, last4: String?, kind: AccountKind, amount: Double, asOf: Date)
    case brokerBalance(broker: String, fund: Double, securities: Double, asOf: Date)
    case turnover(Turnover)
    case mandate(MandateHint)
    case loanDue(lender: String, amount: Double, due: Date, account: String?)
    case ignored(String)
}

/// System hints that decide a category before any merchant matching.
enum TxnHint: String, Codable {
    case none, cardBillPaid, cashDeposit, selfTransfer, refund, interest, brokerPayout, brokerFunding, salary, atm
}

struct ParsedTxn {
    var amount: Double
    var direction: TxnDirection
    var instrument: Instrument
    var bank: String?
    var last4: String?
    var counterparty: String?
    var vpa: String?
    var ref: String?
    var balanceAfter: Double?
    /// The transaction's own time when the text gives one (card alerts give seconds).
    var when: Date?
    /// False for confirmations that repeat another alert (AutoPay success, lender receipts, payout notes,
    /// notifications, e-mails). Duplicates are judged with this.
    var isPrimary: Bool
    var hint: TxnHint = .none
    var pattern: String
}

/// Reads Indian bank, card, UPI, broker and exchange messages.
///
/// Order: OTPs and promotional senders are dropped; then the exact wordings (HDFC Bank's current templates and
/// common ones of other institutions); then information-only messages (balances, turnover, broker balances,
/// mandate notices); then messages that only look like transactions (declined, failed, requests, offers,
/// reminders); and last a generic reader for other banks.
enum MessageParser {

    static let AMT = #"([0-9][0-9,]*(?:\.[0-9]+)?)"#
    static let SAMT = #"(-?[0-9][0-9,]*(?:\.[0-9]+)?)"#

    // MARK: Sender

    struct SenderInfo {
        var code: String?        // "HDFCBK"
        var suffix: String?      // P / S / T / G
        var filterTag: String?   // iOS SMS filter: smsft, smsfp, smsft_fi, …
        var isPromotional: Bool
        var isPersonalNumber: Bool
    }

    private static let senderRx = Rx(#"^[A-Z]{2}-([A-Z0-9]{3,8})(?:-([PSTG]))?$"#)
    private static let filterRx = Rx(#"\((sms[a-z_]*)\)\s*$"#)

    static func senderInfo(_ raw: String) -> SenderInfo {
        var s = raw.trimmed
        var tag: String?
        if let g = filterRx.match(s) {
            tag = g[1]?.lowercased()
            s = filterRx.replace(s, with: "").trimmed
        }
        var code: String?
        var suffix: String?
        if let g = senderRx.match(s.uppercased()) {
            code = g[1]
            suffix = g[2]
        } else if s.range(of: #"^[A-Za-z]{4,8}$"#, options: .regularExpression) != nil {
            code = s.uppercased()
        }
        let digits = s.filter { $0.isNumber }
        let personal = s.hasPrefix("+") ? (digits.count >= 12) : (digits.count == 10 && digits.count == s.count)
        let promo = suffix == "P" || (tag?.hasPrefix("smsfp") ?? false)
        return SenderInfo(code: code, suffix: suffix, filterTag: tag, isPromotional: promo, isPersonalNumber: personal)
    }

    static let bankCodes: [String: String] = [
        "HDFCBK": "HDFC Bank", "HDFCBN": "HDFC Bank", "HDFCCC": "HDFC Bank",
        "ICICIB": "ICICI Bank", "ICICIT": "ICICI Bank", "ICICIC": "ICICI Bank",
        "SBIINB": "SBI", "SBIUPI": "SBI", "ATMSBI": "SBI", "CBSSBI": "SBI", "SBIBNK": "SBI", "SBICRD": "SBI Card", "SBMSMS": "SBI",
        "AXISBK": "Axis Bank", "AXISMR": "Axis Bank", "AXISCC": "Axis Bank",
        "KOTAKB": "Kotak Bank", "KOTAKN": "Kotak Bank", "KOTAKC": "Kotak Bank",
        "YESBNK": "Yes Bank", "IDFCFB": "IDFC First Bank", "INDUSB": "IndusInd Bank", "UJJIVN": "Ujjivan SFB",
        "PAYTMB": "Paytm Payments Bank", "AIRBNK": "Airtel Payments Bank", "FEDBNK": "Federal Bank",
        "AUBANK": "AU Small Finance Bank", "RBLBNK": "RBL Bank", "RBLCRD": "RBL Bank", "CANBNK": "Canara Bank",
        "PNBSMS": "Punjab National Bank", "BOIIND": "Bank of India", "BOBTXN": "Bank of Baroda", "BOBSMS": "Bank of Baroda",
        "UNIONB": "Union Bank", "IDBIBK": "IDBI Bank", "SCBANK": "Standard Chartered", "CITIBK": "Citi",
        "AMEXIN": "American Express", "HSBCIN": "HSBC", "ONECRD": "OneCard", "SLCEIT": "Slice", "SLICEIT": "Slice",
        "JUPITR": "Jupiter", "FIMONY": "Fi", "DBSBNK": "DBS Bank", "BANDHN": "Bandhan Bank", "IOBCHN": "Indian Overseas Bank",
        "CENTBK": "Central Bank of India", "UCOBNK": "UCO Bank", "KVBANK": "Karur Vysya Bank", "SIBSMS": "South Indian Bank",
        "CUBANK": "City Union Bank", "EQUTAS": "Equitas SFB", "STCBNK": "STC Bank", "KARBNK": "Karnataka Bank",
        "TMBANK": "Tamilnad Mercantile Bank", "DCBBNK": "DCB Bank", "JKBANK": "J&K Bank", "SURYOD": "Suryoday SFB",
    ]

    /// Senders whose money messages are worth reading even though they are not banks.
    static let financeCodes: Set<String> = [
        "PHONPE", "PAYTM", "PYTMPB", "GPAYIN", "AMAZON", "AMZPAY", "MOBKWK", "CRDSAI", "BAJAJF", "BAJFIN", "DHANHQ",
        "ZERODH", "ZRDHA", "UPSTOX", "GROWWI", "GROWW", "ANGELB", "ANGELO", "KOTAKS", "NSESMS", "NSETRA", "NSEIND",
        "BSELTD", "CDSLIN", "NSDLIN", "CAMSPL", "KFINTK", "LICIND", "CREDIN", "AIRFSC", "RZRPAY",
    ]

    static func institution(code: String?, text: String) -> String? {
        if let c = code, let b = bankCodes[c] { return b }
        let lower = text.lowercased()
        let names: [(String, String)] = [
            ("hdfc bank", "HDFC Bank"), ("icici bank", "ICICI Bank"), ("axis bank", "Axis Bank"), ("kotak", "Kotak Bank"),
            ("state bank", "SBI"), ("sbi card", "SBI Card"), ("-sbi", "SBI"), ("yes bank", "Yes Bank"), ("idfc first", "IDFC First Bank"),
            ("indusind", "IndusInd Bank"), ("ujjivan", "Ujjivan SFB"), ("federal bank", "Federal Bank"), ("au bank", "AU Small Finance Bank"),
            ("rbl bank", "RBL Bank"), ("canara bank", "Canara Bank"), ("bank of baroda", "Bank of Baroda"), ("union bank", "Union Bank"),
            ("punjab national", "Punjab National Bank"), ("paytm payments bank", "Paytm Payments Bank"), ("airtel payments bank", "Airtel Payments Bank"),
            ("standard chartered", "Standard Chartered"), ("onecard", "OneCard"), ("american express", "American Express"),
        ]
        for (k, v) in names where lower.contains(k) { return v }
        return nil
    }

    // MARK: Entry point

    static func parse(_ m: RawMessage) -> [ParsedItem] {
        let info = senderInfo(m.sender)
        let text = normalize(m.text)
        if text.isEmpty { return [.ignored("empty")] }
        if m.source == .sms && info.isPersonalNumber { return [.ignored("personal number")] }
        if otpRx.test(text) { return [.ignored("code / OTP")] }
        if info.isPromotional { return [.ignored("promotional sender")] }

        let bank = institution(code: info.code, text: text)

        for p in exact {
            if let g = p.rx.match(text), let items = p.build(g, m, text, bank), !items.isEmpty {
                return items.map { (item: ParsedItem) -> ParsedItem in
                    guard case .txn(var t) = item else { return item }
                    if m.source != .sms { t.isPrimary = false }
                    if t.bank == nil { t.bank = bank }
                    return .txn(t)
                }
            }
        }

        if let reason = lookalikeReason(text) { return [.ignored(reason)] }

        // Notifications and mail carry news and adverts with rupee amounts ("FIIs buy ₹1,634.33 Cr").
        if m.source != .sms {
            if marketNewsRx.test(text) { return [.ignored("market news")] }
            if brokerApps.contains(m.sender.lowercased()) {
                // From a broker app only money moved in or out of the trading account counts (an investment;
                // the bank's own SMS of the same transfer is the record, this one becomes its repeat).
                guard brokerFundsRx.test(text), let g = moneyRx.match(text), let amt = amount(g[1]), amt > 0 else {
                    return [.ignored("broker app notification")]
                }
                let out = brokerOutRx.test(text)
                return [.txn(ParsedTxn(amount: amt, direction: out ? .credit : .debit, instrument: .account, bank: nil, last4: nil,
                                       counterparty: brokerAppNames[m.sender.lowercased()] ?? "Broker", vpa: nil, ref: nil,
                                       balanceAfter: nil, when: nil, isPrimary: false, hint: out ? .brokerPayout : .brokerFunding,
                                       pattern: "broker-app"))]
            }
            guard paymentPhraseRx.test(text) else { return [.ignored("no payment words")] }
        }

        // Who may create a transaction through the generic reader: banks, payment/broker senders, app
        // notifications and mail; other SMS (shops confirming an order) only when they name an account at a bank.
        let isBankSender = info.code.map { bankCodes[$0] != nil } ?? false
        let isFinanceSender = info.code.map { financeCodes.contains($0) } ?? false
        let namesBankAccount = bankAccountRx.test(text)
        guard m.source != .sms || isBankSender || isFinanceSender || namesBankAccount else {
            return [.ignored("not a bank or payment sender")]
        }
        let trusted = m.source != .sms || isBankSender || isFinanceSender
        // "Cr" / "Dr" mean credit / debit only in a bank's own SMS; elsewhere "Cr" is usually crore.
        if var t = generic(text, trusted: trusted, abbreviations: m.source == .sms && isBankSender) {
            if t.bank == nil { t.bank = bank }
            // Only a bank's own SMS is the record of a payment; everything else confirms one.
            if m.source != .sms || !isBankSender { t.isPrimary = false }
            var out: [ParsedItem] = [.txn(t)]
            if let b = t.balanceAfter, t.instrument != .creditCard, t.instrument != .creditCardUPI, let bk = t.bank {
                out.append(.balance(institution: bk, last4: t.last4, kind: .savings, amount: b, asOf: t.when ?? m.date))
            }
            return out
        }
        return [.ignored("no pattern")]
    }

    static func normalize(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "₹", with: " Rs.")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "Rs. .", with: "Rs.")
        t = t.collapsedSpaces
        t = t.replacingOccurrences(of: "Rs. Rs.", with: "Rs.")
        return t
    }

    // MARK: Helpers

    static func amount(_ s: String?) -> Double? {
        guard let s else { return nil }
        return Money.parse(s)
    }

    private static let dateFormats = [
        "dd/MM/yy", "dd/MM/yyyy", "dd-MM-yy", "dd-MM-yyyy", "dd-MMM-yy", "dd-MMM-yyyy", "dd/MMM/yyyy", "dd/MMM/yy",
        "yyyy-MM-dd", "dd MMM yyyy", "dd MMM yy", "dd.MM.yy", "dd.MM.yyyy", "d-M-yy", "d/M/yy",
    ]
    private static let dateParsers: [DateFormatter] = dateFormats.map { p in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Cal.ist
        f.dateFormat = p
        f.isLenient = false
        return f
    }

    /// "29/05/26", "29-MAY-26", "03-Sep-2026", "04/JUN/2026", "2026-07-04".
    static func parseDate(_ raw: String?) -> Date? {
        guard var s = raw?.trimmed, !s.isEmpty else { return nil }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
        // Title-case month names so en_US_POSIX "MMM" reads "MAY" / "SEP".
        if let r = s.range(of: #"[A-Za-z]{3,4}"#, options: .regularExpression) {
            var mon = String(s[r]).lowercased()
            if mon == "sept" { mon = "sep" }
            s.replaceSubrange(r, with: mon.prefix(1).uppercased() + mon.dropFirst())
        }
        for f in dateParsers {
            if let d = f.date(from: s) {
                let y = Cal.year(d)
                if y >= 2000 && y <= 2100 { return d }
            }
        }
        return nil
    }

    /// "2026-07-04" + "09:54:55" -> exact time.
    static func parseDateTime(_ day: String?, _ time: String?) -> Date? {
        guard let d = parseDate(day) else { return nil }
        guard let t = time?.split(separator: ":").compactMap({ Int($0) }), t.count >= 2 else { return d }
        return Cal.cal.date(bySettingHour: t[0], minute: t[1], second: t.count > 2 ? t[2] : 0, of: d)
    }

    /// The text's own date matters only when it is a different day from the message (late SMS, e-mails).
    static func when(stated: Date?, message: Date) -> Date? {
        guard let s = stated else { return nil }
        if Cal.sameDay(s, message) { return nil }
        if s > message.addingTimeInterval(36 * 3600) { return nil } // never in the future of the message
        return Cal.cal.date(bySettingHour: 12, minute: 0, second: 0, of: s)
    }

    static func cleanName(_ s: String?) -> String? {
        guard var t = s?.trimmed, !t.isEmpty else { return nil }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:-_*/ "))
        while t.hasPrefix(".") || t.hasPrefix("*") { t.removeFirst() }
        t = t.collapsedSpaces
        if t.isEmpty || t.uppercased() == "NA" || t.uppercased() == "N/A" { return nil }
        return t
    }

    static func isVPA(_ s: String?) -> Bool {
        guard let s else { return false }
        return s.contains("@") && !s.contains(" ")
    }

    private static let bankAccountRx = Rx(#"\b(a/c|acct|account)\b.*\bbank\b|\bbank\b.*\b(a/c|acct|account)\b"#)

    private static let otpRx = Rx(#"\b(otp|one[- ]time password|verification code|security code|confirmation code|login code|registration code|is your [a-z ]*code)\b|\bcode[: ]+\d{4,8}\b|\byour [a-z]+ code is\b"#)

    // MARK: Exact wordings

    private struct Pattern {
        let name: String
        let rx: Rx
        let build: (_ g: [String?], _ m: RawMessage, _ text: String, _ bank: String?) -> [ParsedItem]?
    }

    private static func cardInstrument(_ text: String, defaultCredit: Bool) -> Instrument {
        let u = text.uppercased()
        if u.contains("BLOCK CC") || u.contains("CREDIT CARD") { return .creditCard }
        if u.contains("BLOCK DC") || u.contains("DEBIT CARD") { return .debitCard }
        return defaultCredit ? .creditCard : .debitCard
    }

    private static let exact: [Pattern] = {
        var p: [Pattern] = []
        let A = AMT

        // HDFC UPI from a savings account.
        p.append(Pattern(name: "upi-sent", rx: Rx(#"^Sent Rs\.?\s?"# + A + #" From (.+?) A/C \*?X*(\d{3,6}) To (.+?) On (\d{1,2}/\d{1,2}/\d{2,4}) Ref (\d+)"#)) { g, m, _, _ in
            guard let amt = amount(g[1]) else { return nil }
            let payee = cleanName(g[4])
            return [.txn(ParsedTxn(amount: amt, direction: .debit, instrument: .upi, bank: cleanName(g[2]), last4: g[3],
                                   counterparty: payee, vpa: isVPA(payee) ? payee : nil, ref: g[6], balanceAfter: nil,
                                   when: when(stated: parseDate(g[5]), message: m.date), isPrimary: true, pattern: "upi-sent"))]
        })
        p.append(Pattern(name: "upi-mandate", rx: Rx(#"^UPI Mandate:\s*Sent Rs\.?\s?"# + A + #" from (.+?) A/c \*?X*(\d{3,6}) To (.+?) (\d{1,2}/\d{1,2}/\d{2,4}) Ref (\d+)"#)) { g, m, _, _ in
            guard let amt = amount(g[1]) else { return nil }
            return [.txn(ParsedTxn(amount: amt, direction: .debit, instrument: .upi, bank: cleanName(g[2]), last4: g[3],
                                   counterparty: cleanName(g[4]), vpa: nil, ref: g[6], balanceAfter: nil,
                                   when: when(stated: parseDate(g[5]), message: m.date), isPrimary: true, pattern: "upi-mandate"))]
        })
        // HDFC debit card (and older wording).
        p.append(Pattern(name: "card-spent", rx: Rx(#"^Spent Rs\.?\s?"# + A + #" From (.+?) Card x?(\d{4}) At (.+?) On (\d{4}-\d{2}-\d{2}):(\d{2}:\d{2}:\d{2})(?:\s*Bal Rs\.?\s?"# + A + #")?"#)) { g, m, text, _ in
            guard let amt = amount(g[1]) else { return nil }
            // The balance here is the linked account's, but the message does not say which account: the daily
            // "Available Bal" message keeps that account's balance instead.
            return [.txn(ParsedTxn(amount: amt, direction: .debit, instrument: cardInstrument(text, defaultCredit: false), bank: cleanName(g[2]), last4: g[3],
                                   counterparty: cleanName(g[4]), vpa: nil, ref: nil, balanceAfter: amount(g[7]),
                                   when: parseDateTime(g[5], g[6]), isPrimary: true, pattern: "card-spent"))]
        })
        p.append(Pattern(name: "card-spent-old", rx: Rx(#"^Rs\.?\s?"# + A + #" spent on (.+?) Card x?(\d{4}) at (.+?) on (\d{4}-\d{2}-\d{2}):(\d{2}:\d{2}:\d{2})(?:\s*Avl bal:?\s?"# + A + #")?"#)) { g, _, text, _ in
            guard let amt = amount(g[1]) else { return nil }
            return [.txn(ParsedTxn(amount: amt, direction: .debit, instrument: cardInstrument(text, defaultCredit: false), bank: cleanName(g[2]), last4: g[3],
                                   counterparty: cleanName(g[4]), vpa: nil, ref: nil, balanceAfter: amount(g[7]),
                                   when: parseDateTime(g[5], g[6]), isPrimary: true, pattern: "card-spent-old"))]
        })
        // HDFC credit card (non-UPI).
        p.append(Pattern(name: "cc-spent", rx: Rx(#"^Spent Rs\.?\s?"# + A + #" On (.+?) Card (\d{4}) At (.+?) On (\d{4}-\d{2}-\d{2}):(\d{2}:\d{2}:\d{2})"#)) { g, _, text, _ in
            guard let amt = amount(g[1]) else { return nil }
            return [.txn(ParsedTxn(amount: amt, direction: .debit, instrument: cardInstrument(text, defaultCredit: true), bank: cleanName(g[2]), last4: g[3],
                                   counterparty: cleanName(g[4]), vpa: nil, ref: nil, balanceAfter: nil,
                                   when: parseDateTime(g[5], g[6]), isPrimary: true, pattern: "cc-spent"))]
        })
        // HDFC RuPay credit card on UPI. The payee's VPA is masked since Oct 2026 ("*iggy@icici") or "NA".
        p.append(Pattern(name: "cc-upi", rx: Rx(#"^Txn Rs\.?\s?"# + A + #" On (.+?) Card (\d{4}) At (\S+) by UPI (\d+) On (\d{1,2}-\d{1,2})"#)) { g, _, _, _ in
            guard let amt = amount(g[1]) else { return nil }
            let v = g[4].flatMap { $0.uppercased() == "NA" ? nil : $0 }
            return [.txn(ParsedTxn(amount: amt, direction: .debit, instrument: .creditCardUPI, bank: cleanName(g[2]), last4: g[3],
                                   counterparty: v, vpa: v, ref: g[5], balanceAfter: nil, when: nil, isPrimary: true, pattern: "cc-upi"))]
        })
        // Credits.
        p.append(Pattern(name: "credit-vpa", rx: Rx(#"^Credit Alert!\s*Rs\.?\s?"# + A + #" credited to (.+?) A/c X*(\d{3,6}) on (\S+) from VPA (\S+) \(UPI (\d+)\)"#)) { g, m, _, _ in
            guard let amt = amount(g[1]) else { return nil }
            return [.txn(ParsedTxn(amount: amt, direction: .credit, instrument: .upi, bank: cleanName(g[2]), last4: g[3],
                                   counterparty: g[5], vpa: g[5], ref: g[6], balanceAfter: nil,
                                   when: when(stated: parseDate(g[4]), message: m.date), isPrimary: true, pattern: "credit-vpa"))]
        })
        p.append(Pattern(name: "received-imps", rx: Rx(#"^Received!\s*INR\s?"# + A + #" in (.+?) A/c x*(\d{3,6}) On (\S+) For (IMPS|NEFT|RTGS|UPI)\s*-\s*(.+?)\s*-\s*(\S+)\s*Avl bal INR\s?"# + A)) { g, m, _, _ in
            guard let amt = amount(g[1]) else { return nil }
            let who = cleanName(g[6])
            var out: [ParsedItem] = [.txn(ParsedTxn(amount: amt, direction: .credit, instrument: .account, bank: cleanName(g[2]), last4: g[3],
                                                     counterparty: who, vpa: nil, ref: g[7], balanceAfter: amount(g[8]),
                                                     when: when(stated: parseDate(g[4]), message: m.date), isPrimary: true,
                                                     hint: brokerHint(who, credit: true), pattern: "received-imps"))]
            if let b = amount(g[8]) { out.append(.balance(institution: cleanName(g[2]) ?? "Bank", last4: g[3], kind: .savings, amount: b, asOf: m.date)) }
            return out
        })
        p.append(Pattern(name: "deposited", rx: Rx(#"^Update!\s*INR\s?"# + A + #" deposited in (.+?) A/c X*(\d{3,6}) on (\S+) for (.+?)\.\s*Avl bal INR\s?"# + A)) { g, m, _, _ in
            guard let amt = amount(g[1]) else { return nil }
            let info = g[5] ?? ""
            var who: String?
            var hint: TxnHint = .none
            var inst: Instrument = .account
            if let x = Rx(#"(?:NEFT|RTGS|IMPS)\s*Cr-[A-Z0-9]+-([^-]+)"#).match(info) {
                who = cleanName(x[1])
                hint = brokerHint(who, credit: true)
            } else if info.uppercased().contains("CHEQUE") || info.uppercased().contains("CTS") {
                who = "Cheque deposit"; inst = .account
            } else if info.uppercased().contains("SALARY") {
                who = cleanName(info); hint = .salary
            } else {
                who = cleanName(info)
            }
            var out: [ParsedItem] = [.txn(ParsedTxn(amount: amt, direction: .credit, instrument: inst, bank: cleanName(g[2]), last4: g[3],
                                                     counterparty: who, vpa: nil, ref: nil, balanceAfter: amount(g[6]),
                                                     when: when(stated: parseDate(g[4]), message: m.date), isPrimary: true, hint: hint, pattern: "deposited"))]
            if let b = amount(g[6]) { out.append(.balance(institution: cleanName(g[2]) ?? "Bank", last4: g[3], kind: .savings, amount: b, asOf: m.date)) }
            return out
        })
        p.append(Pattern(name: "cash-deposit", rx: Rx(#"^Deposited!\s*INR\s?"# + A + #" in (.+?) A/c X*(\d{3,6}) On (\S+)(?: \S+)? At (.+?) Via Cash Deposit Machine\.?\s*Bal:?\s*INR\s?"# + A)) { g, m, _, _ in
            guard let amt = amount(g[1]) else { return nil }
            var out: [ParsedItem] = [.txn(ParsedTxn(amount: amt, direction: .credit, instrument: .cash, bank: cleanName(g[2]), last4: g[3],
                                                     counterparty: "Cash deposit", vpa: nil, ref: nil, balanceAfter: amount(g[6]),
                                                     when: when(stated: parseDate(g[4]), message: m.date), isPrimary: true, hint: .cashDeposit, pattern: "cash-deposit"))]
            if let b = amount(g[6]) { out.append(.balance(institution: cleanName(g[2]) ?? "Bank", last4: g[3], kind: .savings, amount: b, asOf: m.date)) }
            return out
        })
        // Debits by ACH / NACH / standing instruction, and the bank's repeat of them.
        p.append(Pattern(name: "ach-debit", rx: Rx(#"^UPDATE:\s*INR\s?"# + A + #" debited from (.+?) X*(\d{3,6}) on (\S+)\.\s*Info:\s*(.+?)\.\s*Avl bal:?\s*INR\s?"# + A)) { g, m, _, _ in
            guard let amt = amount(g[1]) else { return nil }
            let who = achPayee(g[5])
            var out: [ParsedItem] = [.txn(ParsedTxn(amount: amt, direction: .debit, instrument: .account, bank: cleanName(g[2]), last4: g[3],
                                                     counterparty: who, vpa: nil, ref: nil, balanceAfter: amount(g[6]),
                                                     when: when(stated: parseDate(g[4]), message: m.date), isPrimary: true,
                                                     hint: brokerHint(who, credit: false), pattern: "ach-debit"))]
            if let b = amount(g[6]) { out.append(.balance(institution: cleanName(g[2]) ?? "Bank", last4: g[3], kind: .savings, amount: b, asOf: m.date)) }
            return out
        })
        p.append(Pattern(name: "payment-alert", rx: Rx(#"^PAYMENT ALERT!\s*INR\s?"# + A + #" deducted from (.+?) A/C No\.? \*?X*(\d{3,6}) towards (.+?)(?: UMRN.*)?$"#)) { g, _, _, _ in
            guard let amt = amount(g[1]) else { return nil }
            let who = cleanName(g[4])
            return [.txn(ParsedTxn(amount: amt, direction: .debit, instrument: .account, bank: cleanName(g[2]), last4: g[3],
                                   counterparty: who, vpa: nil, ref: nil, balanceAfter: nil, when: nil, isPrimary: false,
                                   hint: brokerHint(who, credit: false), pattern: "payment-alert"))]
        })
        p.append(Pattern(name: "netbanking", rx: Rx(#"^Payment Successful!\s*Rs\.?\s?"# + A + #" from A/c \**X*(\d{3,6}) to (.+?) via (.+?) NetBanking"#)) { g, _, _, _ in
            guard let amt = amount(g[1]) else { return nil }
            let who = cleanName(g[3])
            return [.txn(ParsedTxn(amount: amt, direction: .debit, instrument: .netbanking, bank: cleanName(g[4]), last4: g[2],
                                   counterparty: who, vpa: nil, ref: nil, balanceAfter: nil, when: nil, isPrimary: true,
                                   hint: brokerHint(who, credit: false), pattern: "netbanking"))]
        })
        p.append(Pattern(name: "autopay-success", rx: Rx(#"^AutoPay \(E-mandate\) Success!\s*For (.+?) Txn Amt:\s*INR\s?"# + A + #" Dt:\s?(\S+) Via:\s?(.+?) (DC|CC) (\d{4})"#)) { g, m, _, _ in
            guard let amt = amount(g[2]) else { return nil }
            return [.txn(ParsedTxn(amount: amt, direction: .debit, instrument: g[5]?.uppercased() == "CC" ? .creditCard : .debitCard,
                                   bank: cleanName(g[4]), last4: g[6], counterparty: cleanName(g[1]), vpa: nil, ref: nil, balanceAfter: nil,
                                   when: when(stated: parseDate(g[3]), message: m.date), isPrimary: false, pattern: "autopay-success"))]
        })
        // Credit card bill paid, refunds, excess balance.
        p.append(Pattern(name: "card-paid", rx: Rx(#"Payment of Rs\.?\s?"# + A + #" (?:was|has been) credited to your card ending (\d{4})(?: on (\S+?))?\.?$"#)) { g, m, text, bank in
            guard let amt = amount(g[1]) else { return nil }
            return [.txn(ParsedTxn(amount: amt, direction: .credit, instrument: .creditCard, bank: bank, last4: g[2],
                                   counterparty: "Card bill payment", vpa: nil, ref: nil, balanceAfter: nil,
                                   when: when(stated: parseDate(g[3]), message: m.date), isPrimary: true, hint: .cardBillPaid, pattern: "card-paid"))]
        })
        p.append(Pattern(name: "cc-refund", rx: Rx(#"Rs\.?\s?"# + A + #" refunded by (.+?) on (\S+) & adjusted against (.+?) Credit Card (\d{4})"#)) { g, m, _, _ in
            guard let amt = amount(g[1]) else { return nil }
            let refDigits = (g[2] ?? "").components(separatedBy: CharacterSet.decimalDigits.inverted).first { $0.count >= 8 }
            return [.txn(ParsedTxn(amount: amt, direction: .credit, instrument: .creditCard, bank: cleanName(g[4]), last4: g[5],
                                   counterparty: "Refund", vpa: nil, ref: refDigits, balanceAfter: nil,
                                   when: when(stated: parseDate(g[3]), message: m.date), isPrimary: true, hint: .refund, pattern: "cc-refund"))]
        })
        p.append(Pattern(name: "excess-refund", rx: Rx(#"Excess Balance Refunded:\s*Rs\.?\s?"# + A + #" has been credited from your (.+?) Credit Card ending (\d{4}) to your Bank A/c ending (\d{3,6})(?: on (\S+?))?\.?$"#)) { g, m, _, _ in
            guard let amt = amount(g[1]) else { return nil }
            return [.txn(ParsedTxn(amount: amt, direction: .credit, instrument: .account, bank: cleanName(g[2]), last4: g[4],
                                   counterparty: "Credit card excess refund", vpa: nil, ref: nil, balanceAfter: nil,
                                   when: when(stated: parseDate(g[5]), message: m.date), isPrimary: true, hint: .selfTransfer, pattern: "excess-refund"))]
        })
        // Small banks: "A/c XX999 credited Rs 3.00 on 30-06-26-Credit Int from … Bal: Rs 1000.00".
        p.append(Pattern(name: "ac-short", rx: Rx(#"^A/c X*(\d{3,6}) (credited|debited) (?:with |by )?Rs\.?\s?"# + A + #" on (\d{1,2}-\d{1,2}-\d{2,4})-?\s*(.*?)\.\s*Bal:?\s*Rs\.?\s?"# + A)) { g, m, text, bank in
            guard let amt = amount(g[3]) else { return nil }
            let credit = g[2]?.lowercased() == "credited"
            let desc = cleanName(g[5]) ?? ""
            let interest = desc.lowercased().contains("int")
            let inst = institution(code: nil, text: text) ?? bank ?? "Bank"
            return [
                .txn(ParsedTxn(amount: amt, direction: credit ? .credit : .debit, instrument: .account, bank: inst, last4: g[1],
                               counterparty: interest ? "Interest" : (desc.isEmpty ? nil : desc), vpa: nil, ref: nil, balanceAfter: amount(g[6]),
                               when: when(stated: parseDate(g[4]), message: m.date), isPrimary: true, hint: interest ? .interest : .none, pattern: "ac-short")),
                .balance(institution: inst, last4: g[1], kind: .savings, amount: amount(g[6]) ?? 0, asOf: m.date),
            ]
        })
        // Broker payouts told by the broker or its bank (the bank's own credit message is the primary).
        p.append(Pattern(name: "kotak-payout", rx: Rx(#"^Rs:?\s?"# + A + #" has been transferred to your account X*(\d{3,6}) on (\S+?)\.\s.*From Kotak Bank"#)) { g, m, _, _ in
            guard let amt = amount(g[1]) else { return nil }
            return [.txn(ParsedTxn(amount: amt, direction: .credit, instrument: .account, bank: nil, last4: lastDigits(g[2]),
                                   counterparty: "Kotak Securities", vpa: nil, ref: nil, balanceAfter: nil,
                                   when: when(stated: parseDate(g[3]), message: m.date), isPrimary: false, hint: .brokerPayout, pattern: "kotak-payout"))]
        })
        p.append(Pattern(name: "dhan-payout", rx: Rx(#"transferred Rs\.?\s?"# + A + #" to your bank account ending with X*(\d{3,6}) as a part of running account settlement"#)) { g, _, _, _ in
            guard let amt = amount(g[1]) else { return nil }
            return [.txn(ParsedTxn(amount: amt, direction: .credit, instrument: .account, bank: nil, last4: lastDigits(g[2]),
                                   counterparty: "Dhan", vpa: nil, ref: nil, balanceAfter: nil, when: nil, isPrimary: false,
                                   hint: .brokerPayout, pattern: "dhan-payout"))]
        })
        // SBI UPI: no currency marker at all ("A/C X1234 debited by 100.0 on date 21Nov24 trf to NAME Refno 4321…").
        p.append(Pattern(name: "sbi-upi-debit", rx: Rx(#"A/C X*(\d{3,6}) debited by\s?"# + A + #" on date (\S+) trf to (.+?) Ref\s?no\.?\s?(\d+)"#)) { g, m, _, _ in
            guard let amt = amount(g[2]) else { return nil }
            let payee = cleanName(g[4])
            return [.txn(ParsedTxn(amount: amt, direction: .debit, instrument: .upi, bank: "SBI", last4: g[1], counterparty: payee,
                                   vpa: isVPA(payee) ? payee : nil, ref: g[5], balanceAfter: nil, when: nil, isPrimary: true, pattern: "sbi-upi-debit"))]
        })
        p.append(Pattern(name: "sbi-upi-credit", rx: Rx(#"A/[Cc] X*(\d{3,6})(?:-| )?credited by (?:Rs\.?\s?)?"# + A + #" on (?:date )?(\S+) (?:transfer from|trf from|by) (.+?) Ref\s?no\.?\s?(\d+)"#)) { g, m, _, _ in
            guard let amt = amount(g[2]) else { return nil }
            return [.txn(ParsedTxn(amount: amt, direction: .credit, instrument: .upi, bank: "SBI", last4: g[1], counterparty: cleanName(g[4]),
                                   vpa: nil, ref: g[5], balanceAfter: nil, when: nil, isPrimary: true, pattern: "sbi-upi-credit"))]
        })

        // HDFC-style e-mail alerts ("Rs.80.00 has been debited from account 1234 to VPA x@y NAME on 05-03-26 …").
        p.append(Pattern(name: "mail-upi", rx: Rx(#"Rs\.?\s?"# + A + #" has been (debited|credited) (?:from|to) (?:your )?(?:account|a/c) (?:no\.? )?\**X*(\d{3,6}) (?:to|from|by) VPA (\S+)\s*(.*?)\s+on (\d{1,2}-\d{1,2}-\d{2,4})(?:.*?reference number is (\d+))?"#)) { g, m, _, bank in
            guard let amt = amount(g[1]) else { return nil }
            let credit = g[2]?.lowercased() == "credited"
            let name = cleanName(g[5])
            return [.txn(ParsedTxn(amount: amt, direction: credit ? .credit : .debit, instrument: .upi, bank: bank, last4: g[3],
                                   counterparty: name ?? g[4], vpa: g[4], ref: g[7], balanceAfter: nil,
                                   when: when(stated: parseDate(g[6]), message: m.date), isPrimary: false, pattern: "mail-upi"))]
        })

        // Information only.
        p.append(Pattern(name: "avail-bal", rx: Rx(#"Available Bal(?:ance)? in (.+?) A/c X*(\d{3,6}) as on (?:yesterday:\s?)?(\d{1,2}-[A-Za-z]{3}-\d{2,4}) is INR\s?"# + A)) { g, m, _, _ in
            guard let amt = amount(g[4]) else { return nil }
            let d = parseDate(g[3]).flatMap { Cal.cal.date(bySettingHour: 23, minute: 59, second: 0, of: $0) } ?? m.date
            return [.balance(institution: cleanName(g[1]) ?? "Bank", last4: g[2], kind: .savings, amount: amt, asOf: d)]
        })
        p.append(Pattern(name: "low-bal", rx: Rx(#"Bal in (.+?) A/c X*(\d{3,6}) has gone below.*?Yesterday's bal:\s?INR\s?"# + A)) { g, m, _, _ in
            guard let amt = amount(g[3]) else { return nil }
            let y = Cal.addDays(-1, to: m.date)
            let d = Cal.cal.date(bySettingHour: 23, minute: 59, second: 0, of: y) ?? y
            return [.balance(institution: cleanName(g[1]) ?? "Bank", last4: g[2], kind: .savings, amount: amt, asOf: d)]
        })
        p.append(Pattern(name: "broker-balance", rx: Rx(#"^([A-Z0-9 .&]+?) on (\d{2}-\d{2}-\d{4}) reported your Fund bal Rs\.?\s?"# + SAMT + #" & Securities bal "# + SAMT)) { g, m, _, _ in
            guard let fund = amount(g[3]), let sec = amount(g[4]) else { return nil }
            return [.brokerBalance(broker: brokerName(g[1] ?? ""), fund: fund, securities: sec, asOf: parseDate(g[2]) ?? m.date)]
        })
        p.append(Pattern(name: "bse-trade", rx: Rx(#"BSE Trade Confirmation Client Code (\S+) - Broker (\d+) - EQ Value Rs\.?\s?"# + A + #" - FNO Value Rs\.?\s?"# + A + #" - Currency Value Rs\.?\s?"# + A + #" - Dated (\d{2}-\d{2}-\d{4})"#)) { g, m, _, _ in
            let d = parseDate(g[6]) ?? m.date
            var out: [ParsedItem] = []
            if let v = amount(g[3]), v > 0 { out.append(.turnover(Turnover(date: d, exchange: "BSE", segment: "EQ", value: v))) }
            if let v = amount(g[4]), v > 0 { out.append(.turnover(Turnover(date: d, exchange: "BSE", segment: "FO", value: v))) }
            if let v = amount(g[5]), v > 0 { out.append(.turnover(Turnover(date: d, exchange: "BSE", segment: "CD", value: v))) }
            return out.isEmpty ? [.ignored("BSE: no turnover")] : out
        })
        p.append(Pattern(name: "nse-traded", rx: Rx(#"traded value for (\d{1,2}-[A-Za-z]{3}-\d{2,4}) (FO|CM|CD|COM|EQ|SLB|CO) Rs\.?\s?"# + A)) { g, m, _, _ in
            guard let v = amount(g[3]) else { return nil }
            return [.turnover(Turnover(date: parseDate(g[1]) ?? m.date, exchange: "NSE", segment: (g[2] ?? "FO").uppercased(), value: v))]
        })
        p.append(Pattern(name: "e-mandate", rx: Rx(#"Rs\.?\s?"# + A + #" will be (?:deducted|debited) on (\d{1,2}/\d{1,2}/\d{2,4}).*?\bFor (.+?) mandate"#)) { g, m, _, _ in
            guard let v = amount(g[1]) else { return nil }
            let purpose = cleanName(g[3]) ?? ""
            return [.mandate(MandateHint(amount: v, due: parseDate(g[2]) ?? m.date, purpose: purpose, category: mandateCategory(purpose)))]
        })
        p.append(Pattern(name: "loan-due", rx: Rx(#"EMI of Rs\.?\s?"# + A + #" against your loan a/c(?: number| no\.?)? (\S+) is due on (\S+?)\.?\s"#)) { g, m, text, _ in
            guard let v = amount(g[1]) else { return nil }
            return [.loanDue(lender: lenderName(text), amount: v, due: parseDate(g[3]) ?? m.date, account: g[2])]
        })
        p.append(Pattern(name: "loan-receipt", rx: Rx(#"received a payment of INR\s?"# + A + #" .*against your Loan A/C"#)) { _, _, _, _ in
            [.ignored("lender receipt (the bank's debit is the record)")]
        })
        return p
    }()

    // MARK: Look-alikes that are not transactions

    private static let lookalikes: [(String, Rx)] = [
        ("declined", Rx(#"\b(declined|unsuccessful|could not be (?:processed|completed)|insufficient (?:funds|balance))\b"#)),
        ("failed", Rx(#"\bhas failed\b|\bfailed\b.*\b(payment|transaction|txn)\b|\b(payment|transaction|txn)\b.*\bfailed\b|unable to (?:pay|process)"#)),
        ("payment request", Rx(#"has requested (?:a )?(?:payment|money)|requested money|collect request|payment request|request(?:ed)? (?:of|for) Rs"#)),
        ("future debit", Rx(#"will be (?:debited|deducted|charged|auto-?debited|presented)|is scheduled|upcoming (?:debit|payment)"#)),
        ("reminder", Rx(#"\bis due\b|\bdue (?:on|date|by)\b|minimum (?:amount )?due|total (?:amount )?due|bill (?:of|for) Rs\.?\s?[0-9,.]+ (?:is|has been) generated|\bstatement\b|kindly ignore if paid|pay now|avoid (?:late|penal)"#)),
        ("cancelled", Rx(#"\b(cancelled|canceled|revoked)\b"#)),
        ("offer", Rx(#"\b(voucher|offer|cashback & more|apply now|avail now|pre-?approved|you(?:'re| are) (?:eligible|selected)|loan of|loan on card|smart ?emi|easy ?emi|convert .{0,30}(?:to|into) (?:simple |easy )?(?:monthly )?emi|can be paid in parts|get up to|discount|congrats|lowest (?:rate|roi)|interest rate starts|instant loan|check (?:your )?(?:loan )?offer|t&c|tnc)\b"#)),
        ("mandate set up", Rx(#"mandate (?:has been )?(?:created|registered|set up|successfully registered)|autopay (?:set up|registered|created)"#)),
    ]

    static func lookalikeReason(_ text: String) -> String? {
        for (reason, rx) in lookalikes where rx.test(text) { return reason }
        return nil
    }

    // MARK: Generic reader for other banks and payment apps

    private static let moneyRx = Rx(#"(?:Rs\.?|INR)\s*:?\s*([0-9][0-9,]*(?:\.[0-9]+)?)"#)
    private static let debitWordRx = Rx(#"\b(debited|debit(?! card)|spent|sent|paid|withdrawn|withdrawal|deducted|purchase[d]?|charged|txn of|transaction of|used at|used for|transferred to)"#)
    private static let creditWordRx = Rx(#"\b(credited|credit(?! card)(?! limit)|received|deposited|refund(?:ed)?|reversed|reversal|cashback)"#)
    private static let debitAbbrevRx = Rx(#"\bdr\b"#)
    private static let creditAbbrevRx = Rx(#"\bcr\b"#)

    /// Market news and adverts that broker and bank apps push with rupee amounts in them.
    private static let marketNewsRx = Rx(#"\b(fiis?|diis?|net (?:inflow|outflow)|market (?:update|wrap|cap)|ipo|gmp|sensex|nifty|bank ?nifty|nasdaq|dow jones|crores?|lakh crore|\d[\d,.]*\s?cr)\b"#)
    /// Words without which a notification or mail is not a payment.
    private static let paymentPhraseRx = Rx(#"\b(paid|sent|received|debited|credited|spent|withdrawn|deducted|refund(?:ed)?|payment (?:of|successful|done|received)|transferred|txn|transaction)\b"#)
    private static let brokerOutRx = Rx(#"\b(withdraw\w*|payout|settlement|transferred to your bank|credited to your bank)\b"#)
    private static let brokerFundsRx = Rx(#"\b(funds?|amount|money)\b.*\b(added|withdrawn|credited|debited|transferred|received|payout)\b|\bpayout\b|\bwithdrawal\b.*\b(processed|successful|completed)\b"#)
    static let brokerApps: Set<String> = ["com.dhan.live", "com.zerodha.kite3", "com.kotak.neo", "in.upstox.pro", "in.upstox.app",
                                          "com.upstox.pro", "com.nextbillion.groww", "com.groww.app", "in.groww.app", "com.msf.angelmobile",
                                          "com.angelbroking.angelmobile", "com.angelone.app"]
    private static let brokerAppNames: [String: String] = ["com.dhan.live": "Dhan", "com.zerodha.kite3": "Zerodha", "com.kotak.neo": "Kotak Securities",
                                                            "in.upstox.pro": "Upstox", "com.nextbillion.groww": "Groww", "com.msf.angelmobile": "Angel One"]
    private static let contextRx = Rx(#"\b(a/c|acct|account|card|upi|vpa|bank|imps|neft|rtgs|wallet|atm|txn|transaction|ref)\b"#)
    private static let cardLast4Rx = Rx(#"(?:credit card|debit card|card|cc|dc)\s*(?:no\.?|number)?\s*(?:ending(?: with)?|xx|x|\*+)?\s*[x*]*\s*(\d{4})\b"#)
    private static let acctLast4Rx = Rx(#"(?:a/c|acct|account|ac)\.?\s*(?:no\.?|number)?\s*[:.]?\s*[x*]*\s*(\d{3,6})\b"#)
    private static let vpaRx = Rx(#"(?:vpa|upi id)\s*:?\s*([A-Za-z0-9.\-_*]+@[A-Za-z0-9.\-]+)"#)
    /// A UPI ID anywhere ("to swiggy@icici on"), but not an e-mail address ("care@bank.com").
    private static let anyVPARx = Rx(#"(?<![A-Za-z0-9.\-_])([A-Za-z0-9.\-_*]{2,}@[A-Za-z][A-Za-z0-9]{1,15})(?![A-Za-z0-9]|\.[A-Za-z])"#)
    /// Axis / IDFC style: "UPI/P2M/123456789012/SWIGGY".
    private static let upiPathRx = Rx(#"UPI/P2[AM]/(\d{6,})/([^/]+?)(?:/|\s+Not you|\s+Not You|\.|$)"#)
    private static let semicolonPayeeRx = Rx(#";\s*([A-Za-z0-9][A-Za-z0-9 .&*'\-]{1,40}?)\s+credited"#)
    private static let toPayeeRx = Rx(#"\b(?:at|to|towards|for)\s+([A-Za-z0-9][A-Za-z0-9 .&*'/_\-]{1,40}?)(?=\s+(?:on|ref|via|by|using|upi|avl|bal|txn|from|dated|at|has|is|was|\d)\b|[.,;]|$)"#)
    private static let fromPayeeRx = Rx(#"\bfrom\s+([A-Za-z0-9][A-Za-z0-9 .&'\-]{1,40}?)(?=\s+(?:on|ref|via|by|upi|avl|bal|has|is|\d)\b|[.,;(]|$)"#)
    private static let infoRx = Rx(#"\bInfo:?\s*([^.]+)"#)
    private static let refRx = Rx(#"(?:ref(?:erence)?(?:\s*no\.?|\s*number)?|upi\s*ref(?:\s*no\.?)?|rrn|utr|txn\s*id|transaction\s*id|upi)[\s:#.\-]*(\d{6,})"#)
    private static let balRx = Rx(#"(?:avl\.?\s*bal(?:ance)?|available\s*bal(?:ance)?|\bbal(?:ance)?\b)\s*(?:is|:|-)?\s*(?:Rs\.?|INR)?\s*:?\s*(-?[0-9][0-9,]*(?:\.[0-9]+)?)"#)
    private static let notPayeeWords: Set<String> = ["your", "you", "a/c", "account", "acct", "card", "beneficiary", "the", "this", "bank", "upi", "vpa", "self", "mobile", "rs", "inr"]

    static func generic(_ text: String, trusted: Bool, abbreviations: Bool = false) -> ParsedTxn? {
        guard trusted || contextRx.test(text) else { return nil }
        let ns = text as NSString
        // Amounts that are not balances or limits.
        var amt: Double?
        var amtLoc = 0
        for (g, r) in moneyRx.matchRanges(text) {
            let start = max(0, r.location - 22)
            let before = ns.substring(with: NSRange(location: start, length: r.location - start)).lowercased()
            if before.contains("bal") || before.contains("limit") || before.contains("lmt") || before.contains("avl")
                || before.contains("available") || before.contains("outstanding") || before.contains("due") { continue }
            if let v = Self.amount(g[1]), v > 0 { amt = v; amtLoc = r.location; break }
        }
        guard let value = amt else { return nil }

        var d = debitWordRx.matchRanges(text).first?.range.location
        var c = creditWordRx.matchRanges(text).first?.range.location
        if abbreviations {
            if d == nil { d = debitAbbrevRx.matchRanges(text).first?.range.location }
            if c == nil { c = creditAbbrevRx.matchRanges(text).first?.range.location }
        }
        let direction: TxnDirection
        switch (d, c) {
        case let (x?, y?): direction = x <= y ? .debit : .credit
        case (_?, nil): direction = .debit
        case (nil, _?): direction = .credit
        default: return nil
        }

        let lower = text.lowercased()
        var inst: Instrument = .unknown
        if lower.contains("credit card") { inst = .creditCard }
        else if lower.contains("debit card") { inst = .debitCard }
        else if lower.contains("upi") || lower.contains("vpa") { inst = .upi }
        else if lower.contains("atm") || lower.contains("withdrawn") || lower.contains("cash withdrawal") { inst = .cash }
        else if lower.contains("net banking") || lower.contains("netbanking") { inst = .netbanking }
        else if lower.contains("wallet") { inst = .wallet }
        else if lower.contains("card") { inst = .debitCard }
        else if lower.contains("neft") || lower.contains("imps") || lower.contains("rtgs") || lower.contains("a/c") || lower.contains("account") { inst = .account }

        var last4: String?
        if inst == .creditCard || inst == .debitCard, let g = cardLast4Rx.match(text) { last4 = g[1] }
        if last4 == nil, let g = acctLast4Rx.match(text) { last4 = g[1] }

        var vpa: String?
        if let g = vpaRx.match(text) { vpa = g[1] } else if let g = anyVPARx.match(text) { vpa = g[1] }

        var payee: String?
        var pathRef: String?
        if let g = upiPathRx.match(text) { payee = cleanName(g[2]); pathRef = g[1] }
        if payee == nil, let g = semicolonPayeeRx.match(text) { payee = cleanName(g[1]) }
        if payee == nil {
            let rx = direction == .credit ? fromPayeeRx : toPayeeRx
            for g in rx.matches(text) {
                guard let cand = cleanName(g[1]) else { continue }
                let first = cand.lowercased().split(separator: " ").first.map(String.init) ?? ""
                if notPayeeWords.contains(first) || cand.range(of: #"^\d+$"#, options: .regularExpression) != nil { continue }
                if cand.lowercased().hasPrefix("vpa") { continue }
                payee = cand
                break
            }
        }
        if payee == nil, let g = infoRx.match(text) { payee = achPayee(g[1]) }
        if payee == nil { payee = vpa }

        var ref: String? = pathRef
        if ref == nil, let g = refRx.match(text) { ref = g[1] }
        var bal: Double?
        for (g, r) in balRx.matchRanges(text) where r.location > amtLoc {
            if let v = Self.amount(g[1]) { bal = v; break }
        }

        var hint: TxnHint = .none
        if inst == .cash && direction == .debit { hint = .atm }
        if direction == .credit && (lower.contains("refund") || lower.contains("reversed") || lower.contains("reversal")) { hint = .refund }
        if direction == .credit && lower.contains("salary") { hint = .salary }
        if direction == .credit && lower.contains("interest") { hint = .interest }
        if hint == .none { hint = brokerHint(payee, credit: direction == .credit) }

        return ParsedTxn(amount: value, direction: direction, instrument: inst, bank: nil, last4: last4, counterparty: payee,
                         vpa: vpa, ref: ref, balanceAfter: bal, when: nil, isPrimary: true, hint: hint, pattern: "generic")
    }

    // MARK: Names

    static func lastDigits(_ s: String?) -> String? {
        guard let s else { return nil }
        let d = s.filter { $0.isNumber }
        return d.isEmpty ? nil : String(d.suffix(4))
    }

    /// "ACH D- BAJAJFINANCE-REF12345" -> "BAJAJFINANCE".
    static func achPayee(_ info: String?) -> String? {
        guard var s = info?.trimmed, !s.isEmpty else { return nil }
        s = Rx(#"^(?:ACH\s*D-|ACH-|NACH-?|ECS-?|UPI-|IMPS-|NEFT-|RTGS-|POS\s|SI-)\s*"#).replace(s, with: "")
        let parts = s.split(separator: "-").map { String($0).trimmed }.filter { !$0.isEmpty }
        return cleanName(parts.first ?? s)
    }

    static let brokerAliases: [(String, String)] = [
        // Not plain "dhan": it is a common word in shop names ("Dhan Lakshmi Stores").
        ("raise securities", "Dhan"), ("raisesecurities", "Dhan"), ("moneylicious", "Dhan"), ("dhanhq", "Dhan"),
        ("zerodha", "Zerodha"), ("kotak securities", "Kotak Securities"), ("kotaksecurities", "Kotak Securities"),
        ("upstox", "Upstox"), ("rksv", "Upstox"), ("nextbillion", "Groww"), ("groww", "Groww"), ("angel one", "Angel One"),
        ("angel broking", "Angel One"), ("angelone", "Angel One"), ("icici securities", "ICICI Direct"), ("icicisec", "ICICI Direct"),
        ("hdfc securities", "HDFC Securities"), ("5paisa", "5paisa"), ("fyers", "Fyers"), ("motilal oswal", "Motilal Oswal"),
        ("sharekhan", "Sharekhan"), ("paytm money", "Paytm Money"), ("indian clearing", "Clearing Corporation"),
        ("iccl", "Clearing Corporation"), ("nse clearing", "Clearing Corporation"), ("bse limited", "BSE"),
    ]

    static func brokerName(_ raw: String) -> String {
        let l = raw.lowercased().replacingOccurrences(of: " ", with: "")
        for (k, v) in brokerAliases where l.contains(k.replacingOccurrences(of: " ", with: "")) { return v }
        return raw.capitalized
    }

    static func isBroker(_ name: String?) -> Bool {
        guard let n = name?.lowercased().replacingOccurrences(of: " ", with: "") else { return false }
        return brokerAliases.contains { n.contains($0.0.replacingOccurrences(of: " ", with: "")) }
    }

    static func brokerHint(_ name: String?, credit: Bool) -> TxnHint {
        isBroker(name) ? (credit ? .brokerPayout : .brokerFunding) : .none
    }

    static func lenderName(_ text: String) -> String {
        let l = text.lowercased()
        if l.contains("credit saison") || l.contains("creditsaison") { return "Credit Saison" }
        if l.contains("bajaj") { return "Bajaj Finance" }
        if l.contains("airtel finance") { return "Airtel Finance" }
        if let b = institution(code: nil, text: text) { return b }
        return "Loan"
    }

    /// "AutoPay Bharat Connect Electricity Bill Payment" -> bills.
    static func mandateCategory(_ purpose: String) -> String? {
        let l = purpose.lowercased()
        if l.contains("electricity") || l.contains("water") || l.contains("gas") || l.contains("postpaid") || l.contains("broadband")
            || l.contains("dth") || l.contains("mobile") || l.contains("bill") { return "bills" }
        if l.contains("insurance") || l.contains("premium") { return "insurance" }
        if l.contains("loan") || l.contains("emi") { return "emi" }
        if l.contains("sip") || l.contains("mutual fund") { return Category.investments }
        if l.contains("netflix") || l.contains("spotify") || l.contains("subscription") || l.contains("youtube") || l.contains("prime") { return "subscriptions" }
        return nil
    }
}
