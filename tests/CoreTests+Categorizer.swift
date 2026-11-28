import Foundation

// Synthetic data only: never put real messages, names, amounts or accounts here.

extension CoreTests {
    static func extraCategorizerTests() {
        print("\n# categoriser (review fixes)")
        let args = CommandLine.arguments
        let path = args.count > 1 ? args[1] : "App/Resources/merchants.json"
        guard let data = FileManager.default.contents(atPath: path), let db = try? MerchantDB(data: data) else {
            check(false, "merchant list loads for the categoriser checks")
            return
        }
        let kinds = Dictionary(uniqueKeysWithValues: Category.builtIns.map { ($0.id, $0.kind) })
        let day = Cal.make(2026, 12, 6, 10, 0)!
        let upiTail = " Not You? Call 18002586161/SMS BLOCK UPI to 7308080808"
        func txn(_ name: String?, vpa: String? = nil, dir: TxnDirection = .debit, amount: Double = 100, date: Date? = nil,
                 raw: String = "", pattern: String? = nil) -> Txn {
            var t = Txn(id: "x", date: date ?? day, amount: amount, direction: dir)
            t.counterparty = name ?? (vpa ?? "")
            t.vpa = vpa
            t.counterpartyKey = Categorizer.key(counterparty: name, vpa: vpa)
            t.raw = raw
            t.pattern = pattern
            return t
        }
        let plain = Categorizer(db: db, rules: [:], knownVPAs: [:], mandates: [], categoryKinds: kinds)
        func cat(_ name: String?, vpa: String? = nil, dir: TxnDirection = .debit, hint: TxnHint = .none) -> Categorization {
            plain.categorize(txn(name, vpa: vpa, dir: dir), hint: hint)
        }

        // Sorting everything again keeps what the merchant list sorted, although each payee now shows the list's own
        // name ("Credit card bill", "Dhan", "Simpl Grocery"). Every alias by name; each merchant also by a payment
        // app's name with the bank's UPI ID, and as money received.
        var all = Ledger(state: LedgerState(), db: db)
        for (i, e) in db.entries.enumerated() {
            guard let aliases = e.a, let first = aliases.first else { continue }
            for (j, a) in aliases.enumerated() {
                var t = txn(a.uppercased())
                t.id = "n\(i).\(j)"
                all.state.txns.append(t)
            }
            var v = txn(first.uppercased(), vpa: "q\(500_000_000 + i)@ybl")
            v.id = "v\(i)"
            var c = txn(first.uppercased(), dir: .credit)
            c.id = "c\(i)"
            all.state.txns += [v, c]
        }
        all.recategorize(onlyUnsorted: true)
        let before = Dictionary(uniqueKeysWithValues: all.state.txns.map { ($0.id, $0.category) })
        all.recategorize(onlyUnsorted: false)
        let moved = all.state.txns.filter { before[$0.id] != $0.category }
        check(moved.isEmpty, "sorting again keeps every merchant's category (\(moved.prefix(5).map { $0.counterparty }))")
        check(!all.state.txns.contains { $0.isPerson || $0.lookupState != LookupState.none }, "and marks none of them as a person or for a lookup")

        // A rule's label is not read as the payee's name once the rule is gone.
        var lr = Ledger(state: LedgerState(), db: db)
        _ = lr.ingest([
            msg("Sent Rs.60.00 From HDFC Bank A/C *1234 To RAVI KUMAR On 06/12/26 Ref 612300000201" + upiTail, id: "q1", date: day),
            msg("Sent Rs.60.00 From HDFC Bank A/C *1234 To RAVI KUMAR On 06/12/26 Ref 612300000202" + upiTail, id: "q2", date: day.addingTimeInterval(600)),
        ])
        lr.setCategory("sms:q1", category: "food", remember: true, label: "Tea")
        let ruled = lr.state.txns.first { $0.id == "sms:q2" }?.category
        lr.removeRule("name:ravi kumar")
        let unruled = lr.state.txns.first { $0.id == "sms:q2" }?.category
        check(ruled == "food" && unruled == Category.uncategorized, "after a rule goes, its label (\"Tea\") does not sort the payment (\(unruled ?? "-"))")

        // The bank SMS shows only a UPI ID and the payment app's notification, a little later, names the payee. Sorted
        // again, the SMS keeps its merchant.
        // Either order: the payment app's notification usually comes before the bank's SMS.
        for smsFirst in [true, false] {
            var ga = Ledger(state: LedgerState(), db: db)
            let sms = msg("Sent Rs.200.00 From HDFC Bank A/C *1234 To Q500000999@ybl On 06/12/26 Ref 612300000501" + upiTail, id: "g1",
                          date: smsFirst ? day : day.addingTimeInterval(20))
            let note = RawMessage(id: "ntf:com.google.paisa:g1:h1", date: smsFirst ? day.addingTimeInterval(20) : day, sender: "com.google.paisa",
                                  text: "₹200.00 paid to Indane Gas", source: .notification)
            _ = ga.ingest(smsFirst ? [sms, note] : [note, sms])
            let first = ga.state.txns.first { $0.id == "sms:g1" }
            ga.recategorize(onlyUnsorted: false)
            let g1 = ga.state.txns.first { $0.id == "sms:g1" }
            check(first?.category == "bills" && g1?.category == "bills" && g1?.lookupState == LookupState.none && g1?.isDuplicate == false,
                  "a payee known by its UPI ID gets and keeps its merchant (\(smsFirst ? "SMS first" : "notification first"): \(first?.category ?? "-"), then \(g1?.category ?? "-"))")
        }

        // Money from a lender or an insurer is not a refund.
        check(cat("BAJAJ FINANCE LTD", dir: .credit).category == Category.transfers, "money from a lender is a loan paid out (a transfer), not a refund")
        check(cat("LIFE INSURANCE CORPORATION OF INDIA", dir: .credit).category == Category.income, "an insurer's payout is income, not a refund")
        check(cat("BAJAJ FINANCE LTD", dir: .credit, hint: .refund).category == Category.refunds, "a refund from a lender is still a refund")

        // First names are not merchants, and an alias written without spaces must be whole words of the name.
        for name in ["TIRUMALA RAO", "ZARA KHAN", "BHIMA SHANKAR", "TANISHQ VERMA", "RATNADEEP DAS", "BYJU THOMAS", "NAYARA SHAIKH"] {
            let r = cat(name)
            check(r.isPerson && r.source != .merchant, "\(name) is a person, not a merchant (\(r.displayName ?? r.category))")
        }
        check(cat("TIRUMALA TIRUPATI DEVASTHANAMS").category == "donations" && cat("BHIMA JEWELLERS").displayName == "Bhima Jewellers",
              "the temple trust and the jeweller still match")
        for name in ["DAVID MARTIN", "PRAMOD MARTIN", "GOLD MART", "KINGSTON", "VEDANT UPADHYAY", "GREAT FITNESS"] {
            let r = cat(name)
            check(r.source != .merchant, "\(name) does not match a merchant inside its words (\(r.displayName ?? r.category))")
        }
        check(cat("ZERODHABROKINGLIMITED").category == Category.investments && cat("BAJAJFINANCELTD").category == "emi",
              "a name run together with a legal word on the end still matches")
        check(cat(nil, vpa: "kuber.k@okaxis").isPerson && cat(nil, vpa: "uber.rides@axisbank").displayName == "Uber",
              "a short UPI token counts only at the start of the ID")

        // Shop words in the keyword list make a business, not a person.
        let shops: [(String, String)] = [("SRI SAI KIRANA", "groceries"), ("MAHALAKSHMI SAREES", "shopping"), ("SANJAY FURNITURE", "home"),
                                         ("RAJU TIFFINS", "food"), ("ST MARYS CHURCH", "donations"), ("SRINIVASA DEVASTHANAM", "donations"),
                                         ("SAI VIDYALAYA", "education"), ("KRISHNA ICE CREAM", "food")]
        for (name, want) in shops {
            let r = cat(name)
            check(r.category == want && !r.isPerson, "\(name) -> \(want), not a person (\(r.category))")
        }

        // Loose words ("store", "mart", "metro", "hotel") decide last; "Sagar" and "Vidya" are names first.
        let loose: [(String, String)] = [("SRI GANESH MOBILE STORE", "shopping"), ("VIJAYA FOOTWEAR STORES", "shopping"),
                                         ("SAI HARDWARE STORES", "shopping"), ("GANESH ELECTRONICS MART", "shopping"), ("METRO SHOES", "shopping"),
                                         ("SAGAR ELECTRONICS", "shopping"), ("SAGAR TRAVELS", "travel"), ("VIDYA BHAVAN SCHOOL", "education"),
                                         ("HOTEL SAI RESIDENCY", "travel"), ("SHARMA GENERAL STORES", "groceries"), ("KRISHNA SAGAR PVT LTD", "food"),
                                         ("HDFC BANK CREDIT CARD", Category.transfers), ("HDFC Bank Credit Card Pay", Category.transfers)]
        for (name, want) in loose {
            let r = cat(name)
            check(r.category == want, "\(name) -> \(want) (\(r.category))")
        }
        for name in ["SAGAR PATIL", "VIDYA SAGAR", "MR SAGAR", "DARSHINI R"] {
            check(cat(name).isPerson, "\(name) is a person, not a restaurant")
        }

        // A mandate notice explains only a debit made under a mandate, and the nearest one of that amount.
        func notice(_ amount: Double, _ due: Date, _ purpose: String) -> MandateHint {
            MandateHint(amount: amount, due: due, purpose: purpose, category: MessageParser.mandateCategory(purpose))
        }
        let mc = Categorizer(db: db, rules: [:], knownVPAs: [:], mandates: [
            notice(499, day, "AutoPay Bharat Connect Broadband Bill Payment"),
            notice(1000, day, "Mutual Fund SIP"),
            notice(523, Cal.addDays(-2, to: day), "AutoPay Bharat Connect Water Bill Payment"),
            notice(523, day, "AutoPay Bharat Connect Electricity Bill Payment"),
            notice(4500, day, "Loan EMI"),
        ], categoryKinds: kinds)
        let next = day.addingTimeInterval(86400)
        let shop = mc.categorize(txn("Swiggy Limited", amount: 499, date: next,
                                     raw: "Sent Rs.499.00 From HDFC Bank A/C *1234 To Swiggy Limited On 07/12/26 Ref 612300000301" + upiTail, pattern: "upi-sent"), hint: .none)
        check(shop.category == "food" && shop.displayName == "Swiggy", "a mandate notice does not claim a shop's UPI payment of the same amount")
        let friend = mc.categorize(txn("RAVI KUMAR", amount: 1000, date: next,
                                       raw: "Sent Rs.1000.00 From HDFC Bank A/C *1234 To RAVI KUMAR On 07/12/26 Ref 612300000302" + upiTail, pattern: "upi-sent"), hint: .none)
        check(friend.isPerson && friend.category == Category.uncategorized, "nor a payment to a person (a SIP notice of the same amount)")
        let bill = mc.categorize(txn("AutoPay Bharat Connec", amount: 499, date: next,
                                     raw: "UPI Mandate: Sent Rs.499.00 from HDFC Bank A/c 1234 To AutoPay Bharat Connec 07/12/26 Ref 612300000303" + upiTail, pattern: "upi-mandate"), hint: .none)
        check(bill.category == "bills" && bill.source == .hint && bill.displayName == "Broadband Bill",
              "a mandate debit to the bill network takes its notice's name (\(bill.displayName ?? "-"))")
        let near = mc.categorize(txn("AutoPay Bharat Connec", amount: 523, date: day.addingTimeInterval(3600),
                                     raw: "UPI Mandate: Sent Rs.523.00 from HDFC Bank A/c 1234 To AutoPay Bharat Connec 06/12/26 Ref 612300000304" + upiTail, pattern: "upi-mandate"), hint: .none)
        check(near.displayName == "Electricity Bill", "of two notices of the same amount, the nearer one (\(near.displayName ?? "-"))")
        let loan = mc.categorize(txn("BAJAJFINANCE", amount: 4500, date: next,
                                     raw: "UPDATE: INR 4,500.00 debited from HDFC Bank XX1234 on 07-DEC-26. Info: ACH D- BAJAJFINANCE-ABCREF123. Avl bal:INR 10,000.00", pattern: "ach-debit"), hint: .none)
        check(loan.source == .merchant && loan.displayName == "Bajaj Finance", "a notice does not rename a known merchant")

        // People's names are not looked up: one word, a number beside it, or a UPI ID that says nothing.
        check(!cat("MANJUNATHA").wantsLookup && !Categorizer.isLookupable(name: "Amma", vpa: nil), "a one-word name is never looked up")
        check(!cat("RAMESH 2").wantsLookup, "nor a name with a number beside it")
        check(!cat("RUPINDER KAUR", vpa: "rupinder.kaur@okaxis").wantsLookup && !Categorizer.isLookupable(name: "RUPINDER KAUR", vpa: "rupinder.kaur@okaxis"),
              "a named person with a UPI ID is not looked up")
        check(Categorizer.isLookupable(name: "Unknownshop Xyz Pvt Ltd", vpa: "q123456789@ybl"), "a business with a shop's QR code still is")
        check(["ravi.k@apl", "ravi123@ikwik", "ravi.k@pnb", "ravi.k@paytm"].allSatisfy { cat(nil, vpa: $0).isPerson }, "UPI IDs on people's handles are people")

        // A UPI ID decides only when it is clear; otherwise the name does.
        check(Categorizer.looksLikePerson(name: "Ramesh Kumar", vpa: "rk1990@") && Categorizer.looksLikePerson(name: "RAMESH KUMAR", vpa: "ramesh_k@oksbi"),
              "a UPI ID that settles nothing leaves it to the name")
        check(Categorizer.looksLikePerson(name: "Ramesh Kumar", vpa: "*esh@okaxis") && !Categorizer.looksLikePerson(name: "*esh@okaxis", vpa: "*esh@okaxis"),
              "a masked UPI ID leaves it to the name, and alone says nothing")
        check(Categorizer.looksLikePerson(name: nil, vpa: "9876543210-2@ybl") && Categorizer.looksLikePerson(name: nil, vpa: "919876543210@ybl"),
              "phone-number UPI IDs with a suffix or 91 in front")
        check(!Categorizer.looksLikePerson(name: "RAMESH KUMAR", vpa: "q123456789@ybl"), "a shop's QR code still decides")
        var pe = Ledger(state: LedgerState(), db: db)
        _ = pe.ingest([
            RawMessage(id: "mail:1:401", date: day, sender: "Bank alerts",
                       text: "You have done a UPI txn · Dear Customer, Rs.500.00 has been debited from account 1234 to VPA rk1990@okaxis RAMESH KUMAR on 06-12-26. Your UPI transaction reference number is 612300000401.",
                       source: .email),
            msg("Sent Rs.500.00 From HDFC Bank A/C *1234 To RAMESH KUMAR On 06/12/26 Ref 612300000401" + upiTail, id: "e1", date: day.addingTimeInterval(60)),
        ])
        let e1 = pe.state.txns.first { $0.id == "sms:e1" }
        check(e1?.vpa == "rk1990@okaxis" && e1?.isPerson == true && !pe.state.txns.contains { $0.lookupState != LookupState.none },
              "a UPI ID from the bank's e-mail does not make a named person a business to look up")
    }
}
