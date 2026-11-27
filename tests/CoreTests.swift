import Foundation

// Logic tests for App/Core, built for the Mac runner by tests/run.sh. Every message below is SYNTHETIC: the
// wording copies real bank templates, but names, numbers and accounts are made up. Never put real messages here.

@main
struct CoreTests {
    static var failures = 0
    static var checks = 0

    static func check(_ ok: Bool, _ what: String, file: String = #file, line: Int = #line) {
        checks += 1
        if ok { print("ok   \(what)") } else { failures += 1; print("FAIL \(what)  (line \(line))") }
    }

    static func msg(_ text: String, sender: String = "AD-HDFCBK-S(smsft_fi)", id: String = UUID().uuidString, date: Date? = nil, source: TxnSource = .sms) -> RawMessage {
        RawMessage(id: "sms:" + id, date: date ?? (Cal.make(2026, 11, 20, 12, 0) ?? Date()), sender: sender, text: text, source: source)
    }

    static func firstTxn(_ items: [ParsedItem]) -> ParsedTxn? {
        for i in items { if case .txn(let t) = i { return t } }
        return nil
    }

    static func ignored(_ items: [ParsedItem]) -> String? {
        if items.count == 1, case .ignored(let w) = items[0] { return w }
        return nil
    }

    static func main() {
        let args = CommandLine.arguments
        let dbPath = args.count > 1 ? args[1] : "App/Resources/merchants.json"
        guard let data = FileManager.default.contents(atPath: dbPath) else { print("cannot read \(dbPath)"); exit(2) }
        let db: MerchantDB
        do { db = try MerchantDB(data: data) } catch { print("merchants.json does not decode: \(error)"); exit(2) }
        check(db.entries.count > 200, "merchant list has \(db.entries.count) entries")
        let cats = Set(Category.builtIns.map { $0.id })
        for e in db.entries where !cats.contains(e.c) { check(false, "merchant \(e.n) has unknown category \(e.c)") }

        parserTests()
        categorizerTests(db)
        ledgerTests(db)
        holidayTests()
        commodityDayTests()
        savedFileTests()
        statsTests()
        ocrTests()
        moneyTests()

        print("\n\(checks) checks, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Parser

    static func parserTests() {
        print("\n# parser")
        var t = firstTxn(MessageParser.parse(msg("Sent Rs.432.00 From HDFC Bank A/C *1234 To Swiggy Limited On 12/03/26 Ref 611122233344 Not You? Call 18002586161/SMS BLOCK UPI to 7308080808")))
        check(t?.amount == 432 && t?.direction == .debit && t?.instrument == .upi && t?.last4 == "1234" && t?.counterparty == "Swiggy Limited" && t?.ref == "611122233344" && t?.isPrimary == true, "HDFC UPI sent")
        t = firstTxn(MessageParser.parse(msg("Sent Rs.75.00 From HDFC Bank A/C *1234 To abcd.xyz12345@ On 05/03/26 Ref 611100000001 Not You? Call 18002586161/SMS BLOCK UPI to 7308080808")))
        check(t?.vpa == "abcd.xyz12345@", "HDFC UPI sent to a (cut) UPI ID")
        t = firstTxn(MessageParser.parse(msg("UPI Mandate: Sent Rs.523.00 from HDFC Bank A/c 1234 To AutoPay Bharat Connec 11/03/26 Ref 622300000001 Not You? Call 18002586161/SMS BLOCK UPI to 7308080808")))
        check(t?.amount == 523 && t?.counterparty == "AutoPay Bharat Connec" && t?.pattern == "upi-mandate", "HDFC UPI mandate")
        t = firstTxn(MessageParser.parse(msg("Spent Rs.250 From HDFC Bank Card x9876 At RSP*SWIGGY FOOD On 2026-03-14:09:30:15 Bal Rs.10000.00 Not You? Call 18002586161/SMS BLOCK DC 9876 to 7308080808")))
        check(t?.amount == 250 && t?.instrument == .debitCard && t?.counterparty == "RSP*SWIGGY FOOD" && t?.balanceAfter == 10000, "HDFC debit card spent")
        if let w = t?.when { check(Cal.hour(w) == 9 && Cal.day(w) == 14, "card time read from the text") } else { check(false, "card time read from the text") }
        t = firstTxn(MessageParser.parse(msg("Rs.199 spent on HDFC Bank Card x9876 at SWIGGY FOOD on 2026-03-15:17:00:00 Avl bal: 5000.00.Not You? Call 18002586161 / SMS BLOCK DC 9876 to 7308080808")))
        check(t?.amount == 199 && t?.counterparty == "SWIGGY FOOD", "HDFC debit card, older wording")
        t = firstTxn(MessageParser.parse(msg("Spent Rs.999.50 On HDFC Bank Card 4321 At Amazon Seller Services On 2026-03-16:19:05:24.Not You? To Block+Reissue Call 18002586161/SMS BLOCK CC 4321 to 7308080808")))
        check(t?.amount == 999.5 && t?.instrument == .creditCard && t?.last4 == "4321", "HDFC credit card spent")
        t = firstTxn(MessageParser.parse(msg("Txn Rs.311.00 On HDFC Bank Card 5555 At swiggyupi@axb by UPI 127400000000 On 06-03 Not You? Call 18002586161/SMS BLOCK CC 5555 to 7308080808")))
        check(t?.instrument == .creditCardUPI && t?.vpa == "swiggyupi@axb" && t?.ref == "127400000000", "HDFC RuPay on UPI")
        t = firstTxn(MessageParser.parse(msg("Txn Rs.288.00 On HDFC Bank Card 5555 At *iggy@icici by UPI 131400000000 On 18-03 Not You? Call 18002586161/SMS BLOCK CC 5555 to 7308080808")))
        check(t?.vpa == "*iggy@icici", "HDFC RuPay on UPI, masked ID")
        t = firstTxn(MessageParser.parse(msg("Txn Rs.777.00 On HDFC Bank Card 5555 At NA by UPI 132100000000 On 30-03 Not You? Call 18002586161/SMS BLOCK CC 5555 to 7308080808")))
        check(t?.amount == 777 && t?.vpa == nil, "HDFC RuPay on UPI, payee NA")
        t = firstTxn(MessageParser.parse(msg("Credit Alert! Rs.1000.00 credited to HDFC Bank A/c XX7777 on 09-03-26 from VPA 9000000000@ybl (UPI 908300000000)")))
        check(t?.direction == .credit && t?.vpa == "9000000000@ybl" && t?.last4 == "7777", "HDFC credit from a UPI ID")
        t = firstTxn(MessageParser.parse(msg("Received! INR 2,000.00 in HDFC Bank A/c xx1234 On 06-03-26 For IMPS -RAZORPAYX ESCROW ACC- 627900000000 Avl bal INR 12,345.67")))
        check(t?.amount == 2000 && t?.counterparty == "RAZORPAYX ESCROW ACC" && t?.balanceAfter == 12345.67, "HDFC IMPS received")
        t = firstTxn(MessageParser.parse(msg("Received! INR 10,000.00 in HDFC Bank A/c xx1234 On 04-03-26 For IMPS -ZERODHABROKINGLIMITED- 630800000000 Avl bal INR 22,345.67")))
        check(t?.hint == .brokerPayout, "IMPS from a broker is a payout")
        var items = MessageParser.parse(msg("Update! INR 25,000.00 deposited in HDFC Bank A/c XX1234 on 10-MAR-26 for NEFT Cr-HDFC0000001-Zerodha Broking Ltd NSE CLI-TEST USER NAME-CMS1490000000000.Avl bal INR 50,000.00. Cheque deposits in A/C are subject to clearing"))
        t = firstTxn(items)
        check(t?.amount == 25000 && t?.counterparty == "Zerodha Broking Ltd NSE CLI" && t?.hint == .brokerPayout, "NEFT credit from a broker")
        check(items.contains { if case .balance(_, let l, _, let a, _) = $0 { return l == "1234" && a == 50000 }; return false }, "balance from a credit message")
        t = firstTxn(MessageParser.parse(msg("Update! INR 5,000.00 deposited in HDFC Bank A/c XX1234 on 08-MAR-26 for CHEQUE DEPOSIT - CTS CLG2 - SOME BRANCH.Avl bal INR 55,000.00. Cheque deposits in A/C are subject to clearing")))
        check(t?.counterparty == "Cheque deposit", "cheque deposit")
        t = firstTxn(MessageParser.parse(msg("Deposited! INR 3,000.00 in HDFC Bank A/c XX1234 On 10/03/26 10:00:00 At Some Place Via Cash Deposit Machine Bal: INR 58,000.00")))
        check(t?.hint == .cashDeposit && t?.direction == .credit, "cash deposit machine")
        t = firstTxn(MessageParser.parse(msg("UPDATE: INR 4,500.00 debited from HDFC Bank XX1234 on 03-MAR-26. Info: ACH D- BAJAJFINANCE-BAJAJREF123. Avl bal:INR 40,000.00")))
        check(t?.amount == 4500 && t?.counterparty == "BAJAJFINANCE" && t?.isPrimary == true, "ACH debit")
        t = firstTxn(MessageParser.parse(msg("PAYMENT ALERT! INR 4500.00 deducted from HDFC Bank A/C No 1234 towards Bajaj Finance UMRN: HDFC7000000000000000")))
        check(t?.counterparty == "Bajaj Finance" && t?.isPrimary == false, "payment alert is a repeat")
        t = firstTxn(MessageParser.parse(msg("Payment Successful! Rs. 15000.00 from A/c **********1234 to ZERODHABROKING via HDFC Bank NetBanking. Not you?Call 18002586161")))
        check(t?.instrument == .netbanking && t?.hint == .brokerFunding && t?.last4 == "1234", "NetBanking to a broker is broker funding")
        t = firstTxn(MessageParser.parse(msg("AutoPay (E-mandate) Success! For Netflix Txn Amt:INR649.00 Dt:03/03/2026 Via:HDFC Bank DC 9876 Mandate ID: AbCdEf Not You? To Block+Reissue Call 18002586161/SMS BLOCK DC 9876 to 7308080808")))
        check(t?.amount == 649 && t?.counterparty == "Netflix" && t?.isPrimary == false, "AutoPay success is a repeat")
        t = firstTxn(MessageParser.parse(msg("HDFC Bank Cardmember, Payment of Rs 12000.00 was credited to your card ending 4321 on 04/MAR/2026.")))
        check(t?.hint == .cardBillPaid && t?.last4 == "4321", "card bill payment received")
        t = firstTxn(MessageParser.parse(msg("Alert! Rs. 450.00 refunded by UPICC-035700000000-07-03-2026 on 09/MAR/2026 & adjusted against HDFC Bank Credit Card 5555 View updated balance here: https://example.invalid/x")))
        check(t?.hint == .refund && t?.ref == "035700000000", "credit card refund")
        t = firstTxn(MessageParser.parse(msg("Excess Balance Refunded: Rs.1500.00 has been credited from your HDFC Bank Credit Card ending 4321 to your Bank A/c ending 1234 on 09-03-26.")))
        check(t?.hint == .selfTransfer && t?.last4 == "1234", "excess card balance back to the bank")
        items = MessageParser.parse(msg("A/c XX999 credited Rs 3.00 on 30-06-26-Credit Int from 01-04-2026 to 30-06-2026. Bal: Rs 1000.00. Call 18002082121 for help-Ujjivan SFB", sender: "CP-UJJIVN-S(smsft)"))
        t = firstTxn(items)
        check(t?.hint == .interest && t?.bank == "Ujjivan SFB", "small bank interest credit")
        check(items.contains { if case .balance(let i, _, _, let a, _) = $0 { return i == "Ujjivan SFB" && a == 1000 }; return false }, "small bank balance")
        t = firstTxn(MessageParser.parse(msg("Rs: 25,000.00 has been transferred to your account XXXXXXXXXX1234 on 10-Mar-2026. Please check with your bank for details. From Kotak Bank", sender: "VK-KOTAKB-S(smsft_fi)")))
        check(t?.isPrimary == false && t?.hint == .brokerPayout, "Kotak payout note")
        t = firstTxn(MessageParser.parse(msg("Dear User We have transferred Rs 1,234.56 to your bank account ending with XXXXXXXXXX1234 as a part of running account settlement vide Ref No PO26000000000000. To continue trading and investing, add funds back to your Dhan account.", sender: "VM-DHANHQ-S")))
        check(t?.amount == 1234.56 && t?.counterparty == "Dhan", "Dhan settlement payout")

        items = MessageParser.parse(msg("Available Bal in HDFC Bank A/c XX1234 as on yesterday:31-MAR-26 is INR 1,23,456.78. Cheques are subject to clearing.For updated A/C Bal dial 18002703333."))
        if case .balance(let inst, let l, _, let a, let d) = items.first ?? .ignored("") {
            check(inst == "HDFC Bank" && l == "1234" && a == 123456.78 && Cal.day(d) == 31, "daily available balance")
        } else { check(false, "daily available balance") }
        items = MessageParser.parse(msg("UPDATE:Bal in HDFC Bank A/c XX1234 has gone below minimum limit of INR 5,000.00.Yesterday's bal:INR 999.99.Chat on WhatsApp Banking:example"))
        if case .balance(_, _, _, let a, _) = items.first ?? .ignored("") { check(a == 999.99, "low balance warning keeps the balance") } else { check(false, "low balance warning keeps the balance") }
        items = MessageParser.parse(msg("ZERODHABROKINGLTD on 14-03-2026 reported your Fund bal Rs.-1234.500 & Securities bal 0.000. This excludes your Bank, DP & PMS bal with the broker-NSE", sender: "JX-NSESMS-S(smsft)"))
        if case .brokerBalance(let b, let f, let s, _) = items.first ?? .ignored("") { check(b == "Zerodha" && f == -1234.5 && s == 0, "NSE fund balance (negative)") } else { check(false, "NSE fund balance") }
        items = MessageParser.parse(msg("BSE Trade Confirmation Client Code ABCD12345X - Broker 1234 - EQ Value Rs 0.00 - FNO Value Rs 100000.00 - Currency Value Rs. 0.00 - Dated 02-03-2026", sender: "AD-BSELTD-S(smsft_fi)"))
        if case .turnover(let tv) = items.first ?? .ignored("") { check(tv.value == 100000 && tv.segment == "FO" && Cal.day(tv.date) == 2, "BSE turnover") } else { check(false, "BSE turnover") }
        items = MessageParser.parse(msg("Dear ABCXXXXX1A,Your traded value for 29-MAR-26 FO Rs 250000.5 Check your registered email. For details contact broker -National Stock Exchange.", sender: "AX-NSETRA-S(smsft_fi)"))
        if case .turnover(let tv) = items.first ?? .ignored("") { check(tv.exchange == "NSE" && tv.value == 250000.5, "NSE turnover") } else { check(false, "NSE turnover") }
        items = MessageParser.parse(msg("E-Mandate! Rs.523.00 will be deducted on 11/03/26, 00:00:00 For AutoPay Bharat Connect Electricity Bill Payment mandate UMN abc@ibl Maintain Balance -HDFC Bank"))
        if case .mandate(let h) = items.first ?? .ignored("") { check(h.amount == 523 && h.category == "bills", "e-mandate notice") } else { check(false, "e-mandate notice") }
        items = MessageParser.parse(msg("Dear Customer, EMI of Rs.4500.0 against your loan a/c number 17000000 is due on 2026-04-03. Please maintain sufficient balance in your registered account to avoid penalty charges. Bajaj Finance", sender: "AD-BAJFIN-S"))
        if case .loanDue(let lender, let a, _, _) = items.first ?? .ignored("") { check(lender == "Bajaj Finance" && a == 4500, "loan EMI due") } else { check(false, "loan EMI due") }

        check(ignored(MessageParser.parse(msg("123456 is your OTP for txn of Rs 500 at XYZ. Do not share.", sender: "AX-HDFCBK-T"))) != nil, "OTP skipped")
        check(ignored(MessageParser.parse(msg("SmartEMI available on spends of Rs.50000 for HDFC Bank Credit Card xx5555.", sender: "JD-HDFCBN-P(smsfp)"))) == "promotional sender", "promotional sender skipped")
        check(ignored(MessageParser.parse(msg("HDFC Bank Credit Card 5555 bill of Rs. 12345 can be paid in parts. Convert txns into EMIs.", sender: "VM-HDFCBN-S(smsft)"))) != nil, "offer from a service sender skipped")
        check(ignored(MessageParser.parse(msg("TXN DECLINED: Rs. 100.00 on 16-03-26 at 18:31:36 On HDFC Bank Debit Card 9876 Reason: Technical failure Please retry the transaction."))) != nil, "declined skipped")
        check(ignored(MessageParser.parse(msg("Sorry! We are unable to pay your bill of Rs. 1000 for Some Electricity Company - 0000000000. Please make a payment before your bill due date. -PhonePe", sender: "JM-PHONPE-S"))) != nil, "failed bill payment skipped")
        check(ignored(MessageParser.parse(msg("SOME SHOP PRIVATE LIMI has requested payment of INR 1000.00. You can pay through this link: https://example.invalid - Razorpay", sender: "AX-RZRPAY-S(smsft_or)"))) != nil, "payment request skipped")
        check(ignored(MessageParser.parse(msg("Your order of Rs 450 from Some Restaurant is on the way. Paid via UPI.", sender: "TX-SWIGGY-S"))) != nil, "shop order SMS never makes a transaction")
        check(ignored(MessageParser.parse(msg("Your Uber code is 1234", sender: "+9150000000(smsft)"))) != nil, "app code skipped")
        check(ignored(MessageParser.parse(msg("Hi Rs 500 send pls", sender: "+919800000000"))) == "personal number", "personal numbers are never read")

        // Other banks (generic reader and their own wordings).
        t = firstTxn(MessageParser.parse(msg("ICICI Bank Acct XX123 debited for Rs 500.00 on 26-Mar-26; SWIGGY credited. UPI:123456789012. Call 18002662 for dispute.", sender: "VM-ICICIT-S")))
        check(t?.amount == 500 && t?.direction == .debit && t?.counterparty == "SWIGGY" && t?.ref == "123456789012", "ICICI UPI debit")
        t = firstTxn(MessageParser.parse(msg("Dear UPI user A/C X1234 debited by 250.0 on date 26Mar26 trf to ZOMATO Refno 123456789012. If not u? call 1800111109. -SBI", sender: "JD-SBIUPI-S")))
        check(t?.amount == 250 && t?.counterparty == "ZOMATO" && t?.bank == "SBI", "SBI UPI debit")
        t = firstTxn(MessageParser.parse(msg("INR 250.00 debited A/c no. XX1234 26-03-26, 10:20:30 UPI/P2M/123456789012/SWIGGY Not you? SMS BLOCKUPI Cust ID to 919951860002 Axis Bank", sender: "AX-AXISBK-S")))
        check(t?.amount == 250 && t?.counterparty == "SWIGGY" && t?.ref == "123456789012" && t?.last4 == "1234", "Axis UPI path")
        t = firstTxn(MessageParser.parse(msg("Sent Rs.250.00 from Kotak Bank AC X1234 to swiggy@icici on 26-03-26.UPI Ref 123456789012. Not you, https://example.invalid", sender: "VK-KOTAKB-S")))
        check(t?.amount == 250 && t?.vpa == "swiggy@icici", "Kotak UPI with a bare UPI ID")
        t = firstTxn(MessageParser.parse(msg("Rs.500.00 credited to your A/c XX1234 by UPI from RAHUL KUMAR on 26-03-26. Ref 123456789012", sender: "AX-CANBNK-S")))
        check(t?.direction == .credit && t?.amount == 500, "generic credit")
        t = firstTxn(MessageParser.parse(RawMessage(id: "ntf:1", date: Date(), sender: "com.google.paisa", text: "Payment successful · ₹250.00 paid to Sharma General Store", source: .notification)))
        check(t?.amount == 250 && t?.isPrimary == false && t?.counterparty == "Sharma General Store", "GPay notification")
        t = firstTxn(MessageParser.parse(RawMessage(id: "mail:1", date: Date(), sender: "Bank alerts", text: "You have done a UPI txn · Dear Customer, Rs.80.00 has been debited from account 1234 to VPA abcd@ybl SOME SHOP on 05-03-26. Your UPI transaction reference number is 611100000001.", source: .email)))
        check(t?.amount == 80 && t?.vpa == "abcd@ybl" && t?.ref == "611100000001" && t?.isPrimary == false, "bank alert e-mail")
        check(ignored(MessageParser.parse(RawMessage(id: "ntf:2", date: Date(), sender: "com.dhan.live", text: "Update on FII-DII Activity · FIIs buy ₹1,634.33 Cr\nDIIs sell ₹556.42 Cr\nNet inflow: ₹1,077.91 Cr", source: .notification))) != nil, "market news from a broker app is not income")
        t = firstTxn(MessageParser.parse(RawMessage(id: "ntf:3", date: Date(), sender: "com.dhan.live", text: "Funds added successfully · ₹5,000.00 has been added to your Dhan account", source: .notification)))
        check(t?.amount == 5000 && t?.hint == .brokerFunding && t?.isPrimary == false, "funds added in a broker app")
        t = firstTxn(MessageParser.parse(RawMessage(id: "ntf:4", date: Date(), sender: "com.zerodha.kite3", text: "Withdrawal processed · ₹2,000 has been transferred to your bank account", source: .notification)))
        check(t?.direction == .credit && t?.hint == .brokerPayout, "withdrawal in a broker app")
        check(ignored(MessageParser.parse(RawMessage(id: "ntf:5", date: Date(), sender: "com.amazon.AmazonIN", text: "Big Billion offer · Get ₹500 off on orders above ₹2,999", source: .notification))) != nil, "advert with amounts in a notification is skipped")
        check(MessageParser.parseDate("29-MAY-26").map { Cal.month($0) } == 5, "date: 29-MAY-26")
        check(MessageParser.parseDate("04/JUN/2026").map { Cal.day($0) } == 4, "date: 04/JUN/2026")
        check(MessageParser.parseDate("03-Sep-2026").map { Cal.month($0) } == 9, "date: 03-Sep-2026")
        check(MessageParser.parseDate("06-10-26").map { Cal.month($0) } == 10, "date: 06-10-26")
        check(MessageParser.senderInfo("AD-HDFCBK-S(smsft_fi)").code == "HDFCBK", "sender code")
        check(MessageParser.senderInfo("VM-HDFCBN-P(smsft)").isPromotional, "-P sender is promotional")
    }

    // MARK: Categorizer

    static func categorizerTests(_ db: MerchantDB) {
        print("\n# categorizer")
        let kinds = Dictionary(uniqueKeysWithValues: Category.builtIns.map { ($0.id, $0.kind) })
        let c = Categorizer(db: db, rules: [:], knownVPAs: ["paytm.s21abcd@pty": ("food", "Tea stall")], mandates: [], categoryKinds: kinds)
        func cat(_ name: String?, vpa: String? = nil, dir: TxnDirection = .debit, hint: TxnHint = .none) -> Categorization {
            var t = Txn(id: "x", date: Date(), amount: 100, direction: dir)
            t.counterparty = name ?? (vpa ?? "")
            t.vpa = vpa
            t.counterpartyKey = Categorizer.key(counterparty: name, vpa: vpa)
            return c.categorize(t, hint: hint)
        }
        check(cat("Swiggy Limited").category == "food", "Swiggy Limited -> food")
        check(cat("RSP*SWIGGY FOOD").category == "food", "card descriptor -> food")
        check(cat("SWIGGY INSTAMART").category == "groceries", "Instamart -> groceries")
        check(cat(nil, vpa: "swiggyinstamart@icici").category == "groceries", "Instamart UPI ID")
        check(cat(nil, vpa: "*iggy@icici").category == "food", "masked Swiggy UPI ID")
        check(cat(nil, vpa: "*mato@hdfcbank").displayName == "Zomato", "masked Zomato UPI ID")
        check(cat(nil, vpa: "*azon@rapl").category == "shopping", "masked Amazon UPI ID")
        check(cat(nil, vpa: "*abcd@pty").source == .history && cat(nil, vpa: "*abcd@pty").category == "food", "masked ID resolved from earlier payments")
        check(cat("Amazon Seller Services").category == "shopping", "Amazon")
        check(cat("Google India Digital Serv").category == "subscriptions", "Google, cut name")
        check(cat("AutoPay Bharat Connec").category == "bills", "Bharat Connect autopay, cut name")
        check(cat("NETFLIX.COM").category == "subscriptions", "Netflix")
        check(cat("SPOTIFY INDIA").category == "subscriptions", "Spotify")
        check(cat("URBAN COMPANY LIMITED").category == "home", "Urban Company")
        check(cat("INSHORTS").category == "subscriptions", "news app")
        check(cat("ISKCON TEMPLE").category == "donations", "temple -> donations")
        check(cat("DECATHLON SPORTS INDIA").category == "shopping", "Decathlon")
        check(cat("BAJAJFINANCE").category == "emi", "Bajaj Finance -> EMI")
        check(cat("Sri Sai Medicals").category == "health", "medicals -> health (name words)")
        check(cat("SOME RANDOM HOTEL").category == "food", "hotel -> food")
        check(cat("RAJ ELECTRICALS AND HARD").category == "shopping", "electricals -> shopping")
        check(cat("RAMESH KUMAR").isPerson, "two-word name is a person")
        check(cat("Mrs ANITA SHARMA").isPerson, "title marks a person")
        check(cat(nil, vpa: "9876543210@ybl").isPerson, "phone-number UPI ID is a person")
        check(!cat(nil, vpa: "paytm.s1abc@pty").isPerson, "Paytm QR is a shop")
        check(cat("ZERODHABROKING", hint: .brokerFunding).category == Category.investments, "money to a broker -> investments")
        check(cat("Zerodha Broking Ltd NSE CLI", dir: .credit, hint: .brokerPayout).category == Category.investments, "payout -> investments")
        check(cat("Card bill payment", dir: .credit, hint: .cardBillPaid).category == Category.transfers, "card bill -> transfers")
        check(cat("Swiggy", dir: .credit).category == Category.refunds, "money back from a shop -> refunds")
        check(cat("SOMEONE", dir: .credit).category == Category.income, "money received -> income")
        check(cat("Unknownshop Xyz Pvt Ltd").wantsLookup, "unknown business -> web lookup")
        check(!cat("abc@okicici").wantsLookup, "UPI ID alone is not looked up")
        check(cat("DHAN LAKSHMI STORES").category != Category.investments, "\"Dhan\" in a shop name is not the broker")
        check(FreeLookup.searchText("RAJ ELECTRICALS AND HAR") == "Raj Electricals And", "lookup text drops the cut word")
        check(DescriptionClassifier.classify("Swiggy is an Indian online food ordering and delivery platform").category == "food", "description -> food")
        check(DescriptionClassifier.classify("Rahul is a given name").person, "description -> a person")
    }

    // MARK: Ledger

    static func ledgerTests(_ db: MerchantDB) {
        print("\n# ledger")
        var l = Ledger(state: LedgerState(), db: db)
        let base = Cal.make(2026, 3, 3, 12, 0)!
        var r = l.ingest([
            msg("UPDATE: INR 4,500.00 debited from HDFC Bank XX1234 on 03-MAR-26. Info: ACH D- BAJAJFINANCE-BAJAJREF123. Avl bal:INR 40,000.00", id: "1", date: base),
            msg("PAYMENT ALERT! INR 4500.00 deducted from HDFC Bank A/C No 1234 towards Bajaj Finance UMRN: HDFC7000000000000000", id: "2", date: base.addingTimeInterval(6 * 3600)),
            msg("Spent Rs.649 From HDFC Bank Card x9876 At NETFLIX.COM On 2026-03-03:18:52:07 Bal Rs.39351.00 Not You? Call 18002586161/SMS BLOCK DC 9876 to 7308080808", id: "3", date: base.addingTimeInterval(7 * 3600)),
            msg("AutoPay (E-mandate) Success! For Netflix Txn Amt:INR649.00 Dt:03/03/2026 Via:HDFC Bank DC 9876 Mandate ID: X Not You? To Block+Reissue Call 18002586161/SMS BLOCK DC 9876 to 7308080808", id: "4", date: base.addingTimeInterval(7 * 3600 + 120)),
            msg("Sent Rs.50.00 From HDFC Bank A/C *1234 To TEA STALL On 03/03/26 Ref 600000000001 Not You? Call 18002586161/SMS BLOCK UPI to 7308080808", id: "5", date: base.addingTimeInterval(3600)),
            msg("Sent Rs.50.00 From HDFC Bank A/C *1234 To TEA STALL On 03/03/26 Ref 600000000002 Not You? Call 18002586161/SMS BLOCK UPI to 7308080808", id: "6", date: base.addingTimeInterval(3700)),
            msg("Available Bal in HDFC Bank A/c XX1234 as on yesterday:02-MAR-26 is INR 44,600.00. Cheques are subject to clearing.", id: "7", date: base.addingTimeInterval(-3600)),
        ])
        check(r.added == 6 && r.duplicates == 2, "6 transactions, 2 of them repeats (added \(r.added), dup \(r.duplicates))")
        let visible = l.state.txns.filter { !$0.isDuplicate }
        check(visible.count == 4, "four payments remain visible")
        check(visible.filter { $0.amount == 50 }.count == 2, "two equal UPI payments with different refs both count")
        check(l.state.txns.first { $0.id == "sms:2" }?.duplicateOf == "sms:1", "payment alert hidden behind the ACH debit")
        check(l.state.txns.first { $0.id == "sms:4" }?.duplicateOf == "sms:3", "AutoPay success hidden behind the card spend")
        check(l.state.balances["HDFC Bank|1234"]?.balance == 40000, "balance follows the newest message")
        check(l.state.txns.first { $0.id == "sms:1" }?.category == "emi", "EMI categorised")

        // A notification arriving before the bank SMS of the same payment: the SMS becomes the record.
        r = l.ingest([
            RawMessage(id: "ntf:a", date: base.addingTimeInterval(9 * 3600), sender: "com.google.paisa", text: "₹321.00 paid to Lakshmi Bakery", source: .notification),
            msg("Sent Rs.321.00 From HDFC Bank A/C *1234 To Q123456789@ybl On 03/03/26 Ref 600000000003 Not You? Call 18002586161/SMS BLOCK UPI to 7308080808", id: "8", date: base.addingTimeInterval(9 * 3600 + 20)),
        ])
        let sms8 = l.state.txns.first { $0.id == "sms:8" }
        check(l.state.txns.first { $0.id == "ntf:a" }?.duplicateOf == "sms:8", "notification hidden behind the bank SMS")
        check(sms8?.counterparty == "Lakshmi Bakery", "payee name taken from the notification")
        check(sms8?.category == "food", "and the name sorts it (bakery)")

        // Rules: sorting one payment sorts the others from the same payee, now and later.
        let tea = l.state.txns.first { $0.id == "sms:5" }!
        check(tea.category == Category.uncategorized || tea.category == "food", "tea stall starts unsorted or food")
        l.setCategory(tea.id, category: "food", remember: true, label: "Tea")
        check(l.state.txns.filter { $0.counterpartyKey == tea.counterpartyKey }.allSatisfy { $0.category == "food" }, "rule applied to the same payee")
        _ = l.ingest([msg("Sent Rs.40.00 From HDFC Bank A/C *1234 To TEA STALL On 04/03/26 Ref 600000000004 Not You? Call 18002586161/SMS BLOCK UPI to 7308080808", id: "9", date: base.addingTimeInterval(86400))])
        let t9 = l.state.txns.first { $0.id == "sms:9" }
        check(t9?.category == "food" && t9?.categorySource == .rule && t9?.counterparty == "Tea", "rule sorts a new payment")

        // Mandate notice explains the next day's debit.
        _ = l.ingest([
            msg("E-Mandate! Rs.523.00 will be deducted on 07/04/26, 00:00:00 For AutoPay Bharat Connect Water Bill Payment mandate UMN x@ibl Maintain Balance -HDFC Bank", id: "10", date: Cal.make(2026, 4, 6, 14, 0)!),
            msg("UPI Mandate: Sent Rs.523.00 from HDFC Bank A/c 1234 To SOME PAYEE NAME 07/04/26 Ref 600000000005 Not You? Call 18002586161/SMS BLOCK UPI to 7308080808", id: "11", date: Cal.make(2026, 4, 7, 7, 0)!),
        ])
        let t11 = l.state.txns.first { $0.id == "sms:11" }
        check(t11?.category == "bills" && t11?.categorySource == .hint, "mandate notice sorts the debit")

        // Ingesting the same messages again changes nothing.
        let before = l.state.txns.count
        _ = l.ingest([msg("Sent Rs.40.00 From HDFC Bank A/C *1234 To TEA STALL On 04/03/26 Ref 600000000004", id: "9", date: base)])
        check(l.state.txns.count == before, "same message twice is added once")

        // Codable round trip.
        if let d = try? JSONEncoder().encode(l.state), let back = try? JSONDecoder().decode(LedgerState.self, from: d) {
            check(back.txns.count == l.state.txns.count && back.rules.count == l.state.rules.count, "state survives saving")
        } else { check(false, "state survives saving") }
        // Older file without newer fields still loads.
        let old = #"{"version":1,"txns":[{"id":"a","date":0,"amount":5,"direction":"debit"}]}"#
        check((try? JSONDecoder().decode(LedgerState.self, from: Data(old.utf8)))?.txns.first?.category == Category.uncategorized, "older file loads")

        // Spending maths: transfers and investments are not spending; refunds reduce it.
        let s = SpendStats(txns: l.state.txns, categories: l.categories)
        let march = s.inMonth(base)
        check(abs(s.spent(march) - (4500 + 649 + 50 + 50 + 321 + 40)) < 0.01, "March spending (\(s.spent(march)))")
        // A saved notification that a newer parser recognises as news is dropped on the next launch.
        var news = Txn(id: "ntf:news", date: base, amount: 1634.33, direction: .credit)
        news.source = .notification
        news.sender = "com.dhan.live"
        news.raw = "Update on FII-DII Activity · FIIs buy ₹1,634.33 Cr"
        l.state.txns.append(news)
        check(l.revalidateSecondary() == 1 && !l.state.txns.contains { $0.id == "ntf:news" }, "saved market news dropped on revalidation")
        var nw = Ledger(state: LedgerState(), db: db)
        nw.state.manual = [ManualItem(name: "Gold", kind: .gold, value: 100000), ManualItem(name: "Loan", kind: .loan, value: 40000)]
        nw.updateBalance(institution: "HDFC Bank", last4: "1234", kind: .savings, amount: 50000, asOf: Date())
        nw.updateBalance(institution: "Dhan", last4: nil, kind: .broker, amount: 1000, asOf: Date())
        check(nw.netWorth().net == 111000, "net worth = bank + broker + assets - liabilities")
        nw.updateBalance(institution: "Kotak Securities", last4: nil, kind: .broker, amount: -2000, asOf: Date())
        let w = nw.netWorth()
        check(w.broker == 1000 && w.liabilities == 42000 && w.net == 109000, "a broker debit balance counts as owed, not as a smaller asset")
        var hist = Ledger(state: LedgerState(), db: db)
        hist.updateBalance(institution: "HDFC Bank", last4: "1234", kind: .savings, amount: 1000, asOf: Cal.make(2026, 9, 28, 23, 59)!)
        hist.updateBalance(institution: "HDFC Bank", last4: "1234", kind: .savings, amount: 5000, asOf: Cal.make(2026, 10, 15, 23, 59)!)
        hist.updateBalance(institution: "HDFC Bank", last4: "1234", kind: .savings, amount: 7000, asOf: Cal.make(2026, 11, 20, 23, 59)!)
        let h = hist.netWorthHistory(now: Cal.make(2026, 11, 27, 12, 0)!)
        check(h.count == 3 && h[0].net == 1000 && h[1].net == 5000 && h[2].net == 7000, "net worth on the 1st of each month from balance history (\(h.map { $0.net }))")
    }

    // MARK: Holidays

    static func commodityDayTests() {
        print("\n# commodity trading day")
        // 24 Nov 2026 (Tuesday) is an NSE holiday; MCX's evening session runs.
        let eve = Cal.make(2026, 11, 24, 20, 30)!
        check(Cal.dayKey(Holidays.tradingDay(forScreenshotAt: eve, commodity: true)) == "2026-11-24", "MCX evening on an NSE holiday is that day")
        check(Cal.dayKey(Holidays.tradingDay(forScreenshotAt: eve)) == "2026-11-23", "an equity screenshot on that holiday is the day before")
        let late = Cal.make(2026, 11, 25, 0, 30)!
        check(Cal.dayKey(Holidays.tradingDay(forScreenshotAt: late, commodity: true)) == "2026-11-24", "after midnight it is still the holiday's evening session")
        let noon = Cal.make(2026, 11, 24, 12, 0)!
        check(Cal.dayKey(Holidays.tradingDay(forScreenshotAt: noon, commodity: true)) == "2026-11-23", "MCX at noon on an NSE holiday: morning session closed")
        let sat = Cal.make(2026, 11, 28, 20, 0)!
        check(Cal.dayKey(Holidays.tradingDay(forScreenshotAt: sat, commodity: true)) == "2026-11-27", "Saturday goes back to Friday")
    }

    static func savedFileTests() {
        print("\n# reading saved files")
        // Entries written by an older build lack fields added later; one damaged entry must not lose the rest.
        let json = """
        {"version":1,
         "txns":[{"id":"a","date":0,"amount":10,"direction":"debit"},
                 {"id":"b","date":0,"amount":"oops","direction":"debit"},
                 {"id":"c","date":0,"amount":5,"direction":"credit","hint":"somethingNew","source":"fax"}],
         "trades":{"2026-11-27|Dhan":{"id":"2026-11-27|Dhan","date":0,"broker":"Dhan","pnl":1234.5}},
         "balances":{"HDFC Bank|1234":{"id":"HDFC Bank|1234","institution":"HDFC Bank","kind":"savings","balance":100,"asOf":0}},
         "rules":{"swiggy":{"key":"swiggy","category":"food","label":"Swiggy"}},
         "manual":[{"name":"Gold","kind":"gold","value":50000}],
         "customCategories":[{"id":"custom.pets","name":"Pets","symbol":"pawprint.fill","colorHex":"#123456","kind":"expense"}],
         "lastSMSRowID":42}
        """
        do {
            let st = try JSONDecoder().decode(LedgerState.self, from: Data(json.utf8))
            check(st.txns.map { $0.id } == ["a", "c"] && st.droppedOnLoad == 1, "a damaged transaction is left out, the rest kept (\(st.txns.count), dropped \(st.droppedOnLoad))")
            check(st.txns.last?.hint == TxnHint.none && st.txns.last?.source == .sms, "unknown values fall back")
            check(st.trades.first?.value.pnl == 1234.5 && st.trades.first?.value.positions.isEmpty == true, "trade day without later fields")
            check(st.balances.first?.value.includeInNetWorth == true && st.balances.first?.value.history.isEmpty == true, "balance without later fields")
            check(st.rules["swiggy"]?.hits == 0 && st.manual.first?.value == 50000 && st.customCategories.first?.builtIn == false, "rule, item and category without later fields")
            check(st.lastSMSRowID == 42, "progress markers kept")
            let again = try JSONDecoder().decode(LedgerState.self, from: try JSONEncoder().encode(st))
            check(again.txns.count == 2 && again.trades.count == 1 && again.droppedOnLoad == 0, "saved again and read back")
        } catch {
            check(false, "saved file decodes: \(error)")
        }
    }

    static func holidayTests() {
        print("\n# holidays")
        check(!Holidays.isTradingDay(Cal.make(2026, 12, 25)!), "Christmas closed")
        check(!Holidays.isTradingDay(Cal.make(2026, 1, 15)!), "15 Jan 2026 extra closure")
        check(Holidays.isTradingDay(Cal.make(2026, 11, 26)!), "26 Nov 2026 open")
        check(!Holidays.isTradingDay(Cal.make(2026, 11, 28)!), "Saturday closed")
        check(Holidays.isTradingDay(Cal.make(2026, 11, 8)!), "Muhurat Sunday counts as a session")
        check(Cal.day(Holidays.tradingDay(forScreenshotAt: Cal.make(2026, 11, 28, 10, 0)!)) == 27, "Saturday screenshot belongs to Friday")
        check(Cal.day(Holidays.tradingDay(forScreenshotAt: Cal.make(2026, 11, 27, 7, 30)!)) == 26, "early-morning screenshot belongs to the day before")
        check(Holidays.india2026.count == 17, "17 gazetted holidays")
        check(Holidays.nse2026.filter { Cal.weekdayMon($0.date) <= 5 && $0.kind == .nse }.count == 15, "15 weekday NSE holidays")
    }

    // MARK: Stats

    static func statsTests() {
        print("\n# trading stats")
        let d = { (day: Int, pnl: Double) in TradeDay(id: "\(day)", date: Cal.make(2026, 11, day)!, broker: "Dhan", pnl: pnl) }
        let s = TradeStats(days: [d(2, 1000), d(3, -400), d(4, -600), d(5, 1500), d(6, 200)])
        check(s.net == 1700, "net")
        check(s.winDays == 3 && s.lossDays == 2, "win/loss days")
        check(abs((s.profitFactor ?? 0) - 2.7) < 0.001, "profit factor")
        check(s.maxDrawdown == -1000, "max drawdown")
        check(s.streaks.win == 2 && s.streaks.loss == 2, "streaks")
    }

    // MARK: Screenshot reader

    static func ocrTests() {
        print("\n# screenshot reader")
        let lines = [
            OCRLine(text: "Positions", x: 0.05, y: 0.08, w: 0.3, h: 0.03),
            OCRLine(text: "Dhan", x: 0.05, y: 0.02, w: 0.15, h: 0.02),
            OCRLine(text: "Total P&L", x: 0.05, y: 0.15, w: 0.3, h: 0.02),
            OCRLine(text: "-2,345.50", x: 0.05, y: 0.18, w: 0.35, h: 0.04),
            OCRLine(text: "NIFTY 26 NOV 24000 CE", x: 0.05, y: 0.30, w: 0.5, h: 0.02),
            OCRLine(text: "-1,845.50", x: 0.70, y: 0.30, w: 0.25, h: 0.02),
            OCRLine(text: "SENSEX 26 NOV 80000 PE", x: 0.05, y: 0.36, w: 0.5, h: 0.02),
            OCRLine(text: "-500.00", x: 0.72, y: 0.36, w: 0.23, h: 0.02),
        ]
        let r = TradeOCRParser.read(lines)
        check(r.broker == "Dhan" && r.kind == .positions, "broker and screen")
        check(r.total == -2345.5, "total P&L with sign (\(r.total.map { String($0) } ?? "nil"))")
        check(r.positions.count == 2 && r.positions.first?.pnl == -1845.5, "position rows")
        check(r.confidence >= 0.7, "rows adding up raise confidence")
        // Dhan's Positions screen layout (made-up values): "Overall P&L" over "₹ 12,345.00 on 1 positions" in green,
        // a closed position row, quantity and average price below it.
        let dhan = [
            OCRLine(text: "11/27 Fri", x: 0.13, y: 0.01, w: 0.12, h: 0.012),
            OCRLine(text: "20:46:10", x: 0.13, y: 0.025, w: 0.15, h: 0.015),
            OCRLine(text: "Positions", x: 0.18, y: 0.083, w: 0.2, h: 0.02),
            OCRLine(text: "Orders", x: 0.41, y: 0.083, w: 0.13, h: 0.02),
            OCRLine(text: "Overall P&L", x: 0.06, y: 0.14, w: 0.14, h: 0.012),
            OCRLine(text: "₹ 12,345.00 on 1 positions", x: 0.06, y: 0.168, w: 0.4, h: 0.02, tint: 1),
            OCRLine(text: "Your P&L for today, Verified by Dhan. Tap to share.", x: 0.1, y: 0.214, w: 0.6, h: 0.012),
            OCRLine(text: "All 1", x: 0.04, y: 0.34, w: 0.12, h: 0.015),
            OCRLine(text: "Closed Positions", x: 0.03, y: 0.403, w: 0.2, h: 0.012),
            OCRLine(text: "SENSEX 03 DEC 83100 PUT", x: 0.05, y: 0.44, w: 0.45, h: 0.016),
            OCRLine(text: "12,345.00", x: 0.79, y: 0.44, w: 0.16, h: 0.016, tint: 1),
            OCRLine(text: "Intraday W Qty. 1,000 x 150.25 BSE", x: 0.05, y: 0.468, w: 0.5, h: 0.013),
            OCRLine(text: "Closed", x: 0.86, y: 0.468, w: 0.09, h: 0.013),
        ]
        let rd = TradeOCRParser.read(dhan)
        check(rd.broker == "Dhan" && rd.kind == .positions && rd.total == 12345 && rd.positions.first?.pnl == 12345 && rd.confidence >= 0.7,
              "Dhan positions screen (total \(rd.total.map { String($0) } ?? "nil"), rows \(rd.positions.count), conf \(rd.confidence))")
        var misread = dhan
        misread[5].text = "2 12,345.00 on 1 positions"   // rupee sign read as a 2
        check(TradeOCRParser.read(misread).total == 12345, "a rupee sign read as a digit is not the total")
        let green = [OCRLine(text: "Kite", x: 0.1, y: 0.02, w: 0.1, h: 0.02), OCRLine(text: "Positions", x: 0.1, y: 0.06, w: 0.2, h: 0.02),
                     OCRLine(text: "Total P&L", x: 0.1, y: 0.2, w: 0.2, h: 0.02), OCRLine(text: "3,200.00", x: 0.55, y: 0.2, w: 0.3, h: 0.03, tint: 1)]
        check(TradeOCRParser.read(green).total == 3200, "colour gives the sign when no +/- is shown")
        let red = [OCRLine(text: "Total P&L", x: 0.1, y: 0.2, w: 0.2, h: 0.02), OCRLine(text: "₹1,250.00", x: 0.55, y: 0.2, w: 0.3, h: 0.03, tint: -1)]
        check(TradeOCRParser.read(red).total == -1250, "red text is a loss")
        let hold = [OCRLine(text: "Holdings (12)", x: 0.1, y: 0.05, w: 0.3, h: 0.02), OCRLine(text: "Current value", x: 0.1, y: 0.15, w: 0.3, h: 0.02),
                    OCRLine(text: "2,45,000.00", x: 0.1, y: 0.18, w: 0.4, h: 0.03), OCRLine(text: "Invested", x: 0.55, y: 0.15, w: 0.3, h: 0.02),
                    OCRLine(text: "2,00,000.00", x: 0.55, y: 0.18, w: 0.4, h: 0.03)]
        let h = TradeOCRParser.read(hold)
        check(h.kind == .holdings && h.currentValue == 245000 && h.invested == 200000, "holdings screen values")

        // A positions screen with both figures: the day's P&L, not "overall" (which counts carried positions' earlier days).
        let both = [OCRLine(text: "Positions", x: 0.05, y: 0.05, w: 0.3, h: 0.02),
                    OCRLine(text: "Overall P&L", x: 0.05, y: 0.12, w: 0.3, h: 0.015),
                    OCRLine(text: "+12,000.00", x: 0.05, y: 0.14, w: 0.3, h: 0.025),
                    OCRLine(text: "Today's P&L", x: 0.55, y: 0.12, w: 0.3, h: 0.015),
                    OCRLine(text: "+4,000.00", x: 0.55, y: 0.14, w: 0.3, h: 0.025),
                    OCRLine(text: "NIFTY FUT", x: 0.05, y: 0.3, w: 0.3, h: 0.02)]
        check(TradeOCRParser.read(both).total == 4000, "today's P&L beats overall on a positions screen (\(TradeOCRParser.read(both).total.map { String($0) } ?? "nil"))")
        // Three labels in a row: each label's own column.
        let cols = [OCRLine(text: "Positions", x: 0.05, y: 0.05, w: 0.3, h: 0.02),
                    OCRLine(text: "Realised P&L", x: 0.05, y: 0.12, w: 0.25, h: 0.015),
                    OCRLine(text: "Unrealised P&L", x: 0.36, y: 0.12, w: 0.25, h: 0.015),
                    OCRLine(text: "Total P&L", x: 0.68, y: 0.12, w: 0.25, h: 0.015),
                    OCRLine(text: "-1,000.00", x: 0.05, y: 0.14, w: 0.25, h: 0.02),
                    OCRLine(text: "-1,345.50", x: 0.36, y: 0.14, w: 0.25, h: 0.02),
                    OCRLine(text: "-2,345.50", x: 0.68, y: 0.14, w: 0.25, h: 0.02)]
        check(TradeOCRParser.read(cols).total == -2345.5, "three-column summary reads the Total column (\(TradeOCRParser.read(cols).total.map { String($0) } ?? "nil"))")
        // Live Text gives lines in reading order only; the reader spaces them evenly down the page.
        let texts = ["11/27 Fri", "Positions", "Orders", "Overall P&L", "₹ 12,345.00 on 1 positions",
                     "Your P&L for today, Verified by Dhan. Tap to share.", "All 1", "Closed Positions",
                     "SENSEX 03 DEC 83100 PUT", "12,345.00", "Intraday W Qty. 1,000 x 150.25 BSE", "Closed"]
        let n = Double(texts.count)
        let plain = texts.enumerated().map { i, t in OCRLine(text: t, x: 0.05, y: Double(i) / n, w: 0.9, h: 0.8 / n) }
        let lt = TradeOCRParser.read(plain)
        check(lt.broker == "Dhan" && lt.kind == .positions && lt.total == 12345, "Dhan screen read as plain lines (total \(lt.total.map { String($0) } ?? "nil"))")
        let mcx = [OCRLine(text: "Positions", x: 0.05, y: 0.05, w: 0.3, h: 0.02), OCRLine(text: "Total P&L", x: 0.05, y: 0.12, w: 0.3, h: 0.015),
                   OCRLine(text: "+2,500.00", x: 0.05, y: 0.14, w: 0.3, h: 0.025),
                   OCRLine(text: "CRUDEOIL 16 DEC 5200 CE", x: 0.05, y: 0.3, w: 0.5, h: 0.02), OCRLine(text: "+2,500.00", x: 0.75, y: 0.3, w: 0.2, h: 0.02)]
        check(TradeOCRParser.read(mcx).commodity, "MCX rows mark the screen as commodity")
        check(!TradeOCRParser.read(dhan).commodity, "index options are not commodity")
    }

    static func moneyTests() {
        print("\n# money")
        check(Money.format(123456.5) == "₹1,23,456.5", "Indian grouping (\(Money.format(123456.5)))")
        check(Money.compact(250000) == "₹2.5L", "lakh (\(Money.compact(250000)))")
        check(Money.compact(12500000) == "₹1.25Cr", "crore (\(Money.compact(12500000)))")
        check(Money.parse("1,23,456.78") == 123456.78, "parse")
        check(Money.signed(-500) == "−₹500", "signed")
    }
}
