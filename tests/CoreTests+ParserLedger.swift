import Foundation

// Synthetic data only: never put real messages, names, amounts or accounts here.

extension CoreTests {
    static func extraParserLedgerTests() {
        print("\n# parser and ledger (review fixes)")
        // An empty merchant list: these checks are about reading and linking messages, not about the list.
        let db = MerchantDB(entries: [])
        func hasBalance(_ items: [ParsedItem]) -> Bool {
            items.contains { if case .balance = $0 { return true }; return false }
        }

        // A card or ATM alert's balance is the linked account's, but the alert does not say which account.
        var items = MessageParser.parse(msg("Withdrawn Rs.2000 From HDFC Bank Card x9876 At +SDAC0123 SOME TOWN On 2026-11-20:10:15:00 Bal Rs.48000.00 Not You? Call 18002586161/SMS BLOCK DC 9876 to 7308080808"))
        var t = firstTxn(items)
        check(t?.amount == 2000 && t?.hint == .atm && !hasBalance(items), "an ATM alert's balance is not kept as a separate account")
        items = MessageParser.parse(msg("Rs.500.00 spent on Debit Card XX4321 at SOME SHOP on 20-11-26. Avl Bal Rs 9500.00", sender: "VM-AXISBK-S"))
        check(firstTxn(items)?.last4 == "4321" && !hasBalance(items), "a debit card alert's balance is not kept under the card number")
        items = MessageParser.parse(msg("Rs.1500.00 withdrawn from A/c XX5678 at ATM SOMEPLACE on 20-11-26. Avl Bal Rs 46000.00", sender: "VM-AXISBK-S"))
        check(items.contains { if case .balance(let i, let l, _, let a, _) = $0 { return i == "Axis Bank" && l == "5678" && a == 46000 }; return false },
              "a balance that names its account is kept for that account")

        // Money that is only promised is not counted: the bank's own message is, when it comes.
        check(ignored(MessageParser.parse(msg("Refund of Rs.1,299.00 for your return of order 123-4567890-1234567 has been processed. It will be credited to your HDFC Bank Credit Card within 2-4 business days.", sender: "AX-AMAZON-S"))) == "not done yet",
              "a refund that will be credited later is not counted yet")
        check(ignored(MessageParser.parse(msg("Your refund of Rs.450.00 has been initiated to your original payment method.", sender: "JD-PHONPE-S"))) == "not done yet",
              "a refund only started is not counted yet")
        t = firstTxn(MessageParser.parse(msg("Rs.5000.00 debited from A/c XX1234 by IMPS. It will be credited to the beneficiary account shortly. IMPS Ref 612300000071", sender: "VM-KOTAKB-S")))
        check(t?.direction == .debit && t?.amount == 5000, "money that will reach someone else is still a debit")
        t = firstTxn(MessageParser.parse(msg("Rs.5000.00 debited from A/c XX1234 for IMPS to A/c XX5678. Beneficiary will be credited shortly. IMPS Ref 612300000072", sender: "VM-KOTAKB-S")))
        check(t?.direction == .debit && t?.amount == 5000, "a debit whose beneficiary will be credited later is still a debit")
        t = firstTxn(MessageParser.parse(msg("Rs.450.00 credited to your A/c XX1234 on 05-11-26 - refund initiated by SOME SHOP.", sender: "VM-AXISBK-S")))
        check(t?.direction == .credit && t?.amount == 450 && t?.hint == .refund, "money credited for a refund the shop started is counted")

        // The card's excess balance back in the savings account: the account's own credit alert is the record.
        let refundText = "Excess Balance Refunded: Rs.1500.00 has been credited from your HDFC Bank Credit Card ending 4321 to your Bank A/c ending 1234 on 09-03-26."
        let creditText = "Update! INR 1,500.00 deposited in HDFC Bank A/c XX1234 on 09-MAR-26 for NEFT Cr-HDFC0000001-CARD EXCESS REFUND-CMS0000000001.Avl bal INR 51,500.00. Cheque deposits in A/C are subject to clearing"
        t = firstTxn(MessageParser.parse(msg(refundText)))
        check(t?.isPrimary == false && t?.hint == .selfTransfer, "excess card balance refund repeats the account's credit alert")
        let mar9 = Cal.make(2026, 3, 9, 11, 0)!
        for refundFirst in [true, false] {
            var l = Ledger(state: LedgerState(), db: db)
            _ = l.ingest([
                msg(refundText, id: "x1", date: refundFirst ? mar9 : mar9.addingTimeInterval(600)),
                msg(creditText, id: "x2", date: refundFirst ? mar9.addingTimeInterval(600) : mar9),
            ])
            let shown = l.state.txns.filter { !$0.isDuplicate }
            let s = SpendStats(txns: l.state.txns, categories: l.categories)
            check(shown.count == 1 && shown.first?.id == "sms:x2" && shown.first?.category == Category.transfers && s.income(s.txns) == 0,
                  "excess card balance refund counted once, as a transfer (\(refundFirst ? "refund SMS first" : "credit alert first"))")
        }

        // RuPay UPI alerts give the day without a year ("On 31-10").
        if let w = firstTxn(MessageParser.parse(msg("Txn Rs.288.00 On HDFC Bank Card 5555 At *abcd@icici by UPI 131400000061 On 31-10 Not You? Call 18002586161/SMS BLOCK CC 5555 to 7308080808",
                                                    date: Cal.make(2026, 11, 1, 0, 3))))?.when {
            check(Cal.year(w) == 2026 && Cal.month(w) == 10 && Cal.day(w) == 31, "RuPay UPI alert after midnight keeps its own day")
        } else { check(false, "RuPay UPI alert after midnight keeps its own day") }
        if let w = firstTxn(MessageParser.parse(msg("Txn Rs.150.00 On HDFC Bank Card 5555 At *abcd@icici by UPI 131400000062 On 31-12 Not You? Call 18002586161/SMS BLOCK CC 5555 to 7308080808",
                                                    date: Cal.make(2027, 1, 1, 0, 5))))?.when {
            check(Cal.year(w) == 2026 && Cal.month(w) == 12 && Cal.day(w) == 31, "31-12 read on 1 January is last year's")
        } else { check(false, "31-12 read on 1 January is last year's") }
        t = firstTxn(MessageParser.parse(msg("Txn Rs.99.00 On HDFC Bank Card 5555 At *abcd@icici by UPI 131400000063 On 20-11 Not You? Call 18002586161/SMS BLOCK CC 5555 to 7308080808")))
        check(t != nil && t?.when == nil, "same-day RuPay UPI alert keeps the message time")
        var late = Ledger(state: LedgerState(), db: db)
        let eve = Cal.make(2026, 10, 31, 23, 58)!
        _ = late.ingest([
            RawMessage(id: "ntf:com.example.pay:n1:h1", date: eve, sender: "com.example.pay", text: "₹288.00 paid to Some Cafe", source: .notification),
            msg("Txn Rs.288.00 On HDFC Bank Card 5555 At *abcd@icici by UPI 131400000064 On 31-10 Not You? Call 18002586161/SMS BLOCK CC 5555 to 7308080808",
                id: "c64", date: eve.addingTimeInterval(5 * 60)),
        ])
        check(late.state.txns.first { $0.id == "sms:c64" }.map { Cal.month($0.date) == 10 } == true
              && late.state.txns.first { $0.id == "ntf:com.example.pay:n1:h1" }?.duplicateOf == "sms:c64",
              "a late RuPay UPI alert is filed on its own day and still hides its notification")

        // One app tells each payment once: two of its notifications are two payments.
        let am = Cal.make(2026, 11, 2, 10, 0)!
        var two = Ledger(state: LedgerState(), db: db)
        _ = two.ingest([
            RawMessage(id: "ntf:com.example.pay:r1:a1", date: am, sender: "com.example.pay", text: "₹20.00 paid to Tea Corner", source: .notification),
            RawMessage(id: "ntf:com.example.pay:r2:a1", date: am.addingTimeInterval(75 * 60), sender: "com.example.pay", text: "₹20.00 paid to Tea Corner", source: .notification),
        ])
        check(two.state.txns.filter { !$0.isDuplicate }.count == 2, "two payments told only by one app both count")
        var mixed = Ledger(state: LedgerState(), db: db)
        _ = mixed.ingest([
            msg("Sent Rs.100.00 From HDFC Bank A/C *1234 To SOME SHOP On 02/11/26 Ref 612300000081 Not You? Call 18002586161/SMS BLOCK UPI to 7308080808", id: "m81", date: am),
            RawMessage(id: "ntf:com.example.pay:r3:b1", date: am.addingTimeInterval(10), sender: "com.example.pay", text: "₹100.00 paid to Some Shop", source: .notification),
            RawMessage(id: "ntf:com.example.pay:r4:b2", date: am.addingTimeInterval(3600), sender: "com.example.pay", text: "₹100.00 paid to Other Stall", source: .notification),
        ])
        check(mixed.state.txns.filter { !$0.isDuplicate }.count == 2 && mixed.state.txns.first { $0.id == "ntf:com.example.pay:r3:b1" }?.duplicateOf == "sms:m81",
              "a second same-amount payment told only by the app is not hidden behind the first one's bank SMS")
        var changed = Ledger(state: LedgerState(), db: db)
        _ = changed.ingest([
            RawMessage(id: "ntf:com.example.pay:r5:c1", date: am, sender: "com.example.pay", text: "Payment of ₹55.00 sent to Juice Bar", source: .notification),
            RawMessage(id: "ntf:com.example.pay:r5:c2", date: am.addingTimeInterval(30), sender: "com.example.pay", text: "₹55.00 paid to Juice Bar", source: .notification),
        ])
        check(changed.state.txns.filter { !$0.isDuplicate }.count == 1, "one notification whose text the app changed counts once")
        // The same mail read again under a new id (Gmail renumbered the mailbox) is not a second payment.
        let n8 = Cal.make(2026, 11, 8, 10, 0)!
        let cardMail = "Card alert · Rs.640.00 spent on your Credit Card XX4321 at SOME STORE on 08-11-26."
        var again = Ledger(state: LedgerState(), db: db)
        _ = again.ingest([RawMessage(id: "mail:1:301", date: n8, sender: "Bank alerts", text: cardMail, source: .email)])
        _ = again.ingest([RawMessage(id: "mail:2:7", date: n8, sender: "Bank alerts", text: cardMail, source: .email)])
        check(again.state.txns.filter { !$0.isDuplicate }.count == 1, "a mail read again under a new id counts once")
        // A mail app shows mail from many senders: two senders' mails about one payment are one payment.
        var gm = Ledger(state: LedgerState(), db: db)
        _ = gm.ingest([
            RawMessage(id: "ntf:com.google.Gmail:m1:a1", date: n8, sender: "com.google.Gmail",
                       text: "Bank alerts · Card used · Rs.640.00 spent on your Credit Card XX4321 at SOME STORE", source: .notification),
            RawMessage(id: "ntf:com.google.Gmail:m2:b1", date: n8.addingTimeInterval(60), sender: "com.google.Gmail",
                       text: "Some Store · Your receipt · You paid Rs.640.00 at Some Store", source: .notification),
        ])
        check(gm.state.txns.filter { !$0.isDuplicate }.count == 1, "two mails about one payment, shown by a mail app, count once")
        _ = gm.ingest([RawMessage(id: "ntf:com.google.Gmail:m3:a1", date: n8.addingTimeInterval(3600), sender: "com.google.Gmail",
                                  text: "Bank alerts · Card used · Rs.640.00 spent on your Credit Card XX4321 at SOME STORE", source: .notification)])
        check(gm.state.txns.filter { !$0.isDuplicate }.count == 2, "a second payment told by the same mail sender still counts")

        // A link by amount and time alone gives the bank's record nothing that could pull in another payment.
        let nb = Cal.make(2026, 11, 3, 9, 10)!
        var funds = Ledger(state: LedgerState(), db: db)
        _ = funds.ingest([
            msg("Payment Successful! Rs. 10000.00 from A/c **********1234 to ZERODHABROKING via HDFC Bank NetBanking. Not you?Call 18002586161", id: "f1", date: nb),
            RawMessage(id: "mail:1:91", date: nb.addingTimeInterval(90 * 60), sender: "Bank alerts",
                       text: "You have done a UPI txn · Dear Customer, Rs.10000.00 has been debited from account 1234 to VPA fundsxyz@ybl SOME BROKER LTD on 03-11-26. Your UPI transaction reference number is 633300000091.", source: .email),
            msg("Sent Rs.10000.00 From HDFC Bank A/C *1234 To SOME BROKER LTD On 03/11/26 Ref 633300000091 Not You? Call 18002586161/SMS BLOCK UPI to 7308080808", id: "f2", date: nb.addingTimeInterval(90 * 60 + 20)),
        ])
        let fv = funds.state.txns.filter { !$0.isDuplicate }
        check(fv.count == 2 && abs(fv.reduce(0) { $0 + $1.amount } - 20000) < 0.01, "two same-amount payments 90 minutes apart both count (\(fv.count) shown)")
        check(funds.state.txns.first { $0.id == "sms:f1" }?.ref == nil, "the bank's record does not take the other payment's reference number")
        var refs = Ledger(state: LedgerState(), db: db)
        let n4 = Cal.make(2026, 11, 4, 18, 0)!
        _ = refs.ingest([
            msg("Sent Rs.75.00 From HDFC Bank A/C *1234 To abcd@ybl On 04/11/26 Ref 612300000101 Not You? Call 18002586161/SMS BLOCK UPI to 7308080808", id: "r1", date: n4),
            RawMessage(id: "mail:1:102", date: n4.addingTimeInterval(1800), sender: "Bank alerts",
                       text: "You have done a UPI txn · Dear Customer, Rs.75.00 has been debited from account 1234 to VPA efgh@ybl SOME STALL on 04-11-26. Your UPI transaction reference number is 612300000102.", source: .email),
        ])
        check(refs.state.txns.filter { !$0.isDuplicate }.count == 2, "messages with different reference numbers are two payments")
        var kind = Ledger(state: LedgerState(), db: db)
        let n7 = Cal.make(2026, 11, 7, 10, 0)!
        _ = kind.ingest([
            msg("Sent Rs.5000.00 From HDFC Bank A/C *1234 To SOME LANDLORD On 07/11/26 Ref 612300000131 Not You? Call 18002586161/SMS BLOCK UPI to 7308080808", id: "h1", date: n7),
            RawMessage(id: "ntf:com.zerodha.kite3:k1:z1", date: n7.addingTimeInterval(1800), sender: "com.zerodha.kite3",
                       text: "Funds added successfully · ₹5,000.00 has been added to your trading account", source: .notification),
        ])
        check(kind.state.txns.first { $0.id == "sms:h1" }?.category != Category.investments,
              "a broker app's note linked by time alone does not turn a bank payment into an investment")

        // A rule re-sorts only what it can change: that payee, and masked UPI IDs that may be it.
        let n5 = Cal.make(2026, 11, 5, 9, 0)!
        var rl = Ledger(state: LedgerState(), db: db)
        _ = rl.ingest([
            msg("Sent Rs.60.00 From HDFC Bank A/C *1234 To shopxyzw@okaxis On 05/11/26 Ref 612300000111 Not You? Call 18002586161/SMS BLOCK UPI to 7308080808", id: "k1", date: n5),
            msg("Txn Rs.45.00 On HDFC Bank Card 5555 At *xyzw@okaxis by UPI 131400000112 On 05-11 Not You? Call 18002586161/SMS BLOCK CC 5555 to 7308080808", id: "k2", date: n5.addingTimeInterval(3600)),
            msg("Sent Rs.30.00 From HDFC Bank A/C *1234 To OTHER PAYEE On 05/11/26 Ref 612300000113 Not You? Call 18002586161/SMS BLOCK UPI to 7308080808", id: "k3", date: n5.addingTimeInterval(7200)),
        ])
        if let i = rl.state.txns.firstIndex(where: { $0.id == "sms:k3" }) {
            rl.state.txns[i].category = "travel"
            rl.state.txns[i].categorySource = .heuristic
        }
        rl.setCategory("sms:k1", category: "groceries", remember: true, label: "Corner Shop")
        let k2 = rl.state.txns.first { $0.id == "sms:k2" }
        check(k2?.category == "groceries" && k2?.categorySource == .rule, "a rule also sorts a masked UPI ID that stands for that payee")
        check(rl.state.txns.first { $0.id == "sms:k3" }?.category == "travel", "a new rule leaves other payees' payments alone")
        rl.removeRule("vpa:shopxyzw@okaxis")
        check(rl.state.txns.first { $0.id == "sms:k2" }?.categorySource == .history, "removing the rule sorts the masked payment again")

        // Once a lookup says "person", the next sync does not undo it, and a person is never queued for a lookup.
        // (The categoriser itself sees a business it would look up.)
        let n6 = Cal.make(2026, 11, 6, 9, 0)!
        var pp = Ledger(state: LedgerState(), db: db)
        _ = pp.ingest([msg("Sent Rs.200.00 From HDFC Bank A/C *1234 To XYZZY VENTURES On 06/11/26 Ref 612300000121 Not You? Call 18002586161/SMS BLOCK UPI to 7308080808", id: "p1", date: n6)])
        let pk = pp.state.txns.first { $0.id == "sms:p1" }?.counterpartyKey ?? ""
        pp.applyLookup(key: pk, category: nil, confident: false, note: nil, source: .web, person: true, name: nil)
        _ = pp.ingest([msg("Sent Rs.30.00 From HDFC Bank A/C *1234 To abcd@ybl On 06/11/26 Ref 612300000122 Not You? Call 18002586161/SMS BLOCK UPI to 7308080808", id: "p2", date: n6.addingTimeInterval(600))])
        let p1 = pp.state.txns.first { $0.id == "sms:p1" }
        check(p1?.isPerson == true && p1?.suggestion == Category.people, "a lookup's \"person\" answer survives the next sync")
        var pq = pp
        if let i = pq.state.txns.firstIndex(where: { $0.id == "sms:p1" }) { pq.state.txns[i].lookupState = LookupState.none }
        pq.recategorize(onlyUnsorted: true)
        check(pq.state.txns.first { $0.id == "sms:p1" }?.lookupState == LookupState.none, "a person is never queued for a lookup")
    }
}
