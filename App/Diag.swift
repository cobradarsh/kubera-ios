import Foundation
import UIKit
import SwiftUI
import UserNotifications

/// Test hooks, off unless Library/Caches/kb-diag exists when the app starts.
/// kubera://_diag/<command>?<args> (or lines in Library/Caches/kb-diag-cmd); results in Library/Caches/kb-diag.log.
enum Diag {
    static var enabled = false
    private static let logURL = Paths.caches.appendingPathComponent("kb-diag.log")
    private static let cmdURL = Paths.caches.appendingPathComponent("kb-diag-cmd")
    private static let q = DispatchQueue(label: "kb.diag")
    private static var timer: Timer?
    private static var lastCmd = ""

    static func setup() {
        enabled = FileManager.default.fileExists(atPath: Paths.caches.appendingPathComponent("kb-diag").path)
        guard enabled else { return }
        log("launch \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "") home=\(NSHomeDirectory())")
        // Command file: one URL path per line ("state", "snapshot?name=home"); each new last line is run.
        DispatchQueue.main.async {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                guard let s = try? String(contentsOf: cmdURL, encoding: .utf8) else { return }
                let line = s.split(separator: "\n").last.map(String.init)?.trimmed ?? ""
                guard !line.isEmpty, line != lastCmd else { return }
                lastCmd = line
                if let u = URL(string: "kubera://_diag/" + line) { Task { @MainActor in handle(u) } }
            }
        }
    }

    static func log(_ s: String) {
        guard enabled else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        q.async {
            if let h = try? FileHandle(forWritingTo: logURL) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                try? line.data(using: .utf8)!.write(to: logURL)
            }
        }
    }

    @MainActor
    static func handle(_ url: URL) {
        guard enabled else { return }
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let cmd = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var a: [String: String] = [:]
        for i in c?.queryItems ?? [] { a[i.name] = i.value ?? "" }
        log("cmd \(cmd) \(a)")
        let store = Store.shared
        let router = Router.shared
        switch cmd {
        case "state":
            let st = store.state
            log("txns=\(st.txns.count) visible=\(st.txns.filter { !$0.isDuplicate }.count) dup=\(st.txns.filter { $0.isDuplicate }.count) unsorted=\(store.uncategorized.count) rules=\(st.rules.count) balances=\(st.balances.count) turnovers=\(st.turnovers.count) trades=\(st.trades.count) mandates=\(st.mandates.count) loans=\(st.loans.count) lastSMS=\(st.lastSMSRowID) ignored=\(st.ignoredCount)")
            log(SMSReader.probe() + " tweak=\(NotificationInbox.tweakSeen) inbox=\(st.inboxOffsets)")
            let nw = store.ledger.netWorth()
            log("networth bank=\(Int(nw.bank)) broker=\(Int(nw.broker)) assets=\(Int(nw.assets)) liab=\(Int(nw.liabilities)) net=\(Int(nw.net))")
            for b in st.balances.values.sorted(by: { $0.id < $1.id }) { log("balance \(b.id) \(b.balance) asOf=\(Cal.dayKey(b.asOf)) points=\(b.history.count)") }
        case "sync":
            Task { await store.sync(reason: "diag") }
        case "txns":
            let n = Int(a["n"] ?? "40") ?? 40
            for t in store.state.txns.suffix(n) {
                log("txn \(Cal.dayKey(t.date)) \(t.direction == .debit ? "-" : "+")\(t.amount) [\(t.category)/\(t.categorySource.rawValue)] \(t.counterparty) vpa=\(t.vpa ?? "-") \(t.instrument.rawValue) \(t.last4 ?? "") \(t.pattern ?? "") \(t.isDuplicate ? "DUP" : "") \(t.isPrimary ? "" : "sec") \(t.isPerson ? "person" : "") sugg=\(t.suggestion ?? "-")")
            }
        case "month":
            let s = store.spend
            let list = s.inMonth(Date())
            log("month spent=\(Int(s.spent(list))) income=\(Int(s.income(list))) invested=\(Int(s.invested(list)))")
            for c in s.byCategory(list) { log("  \(c.category) \(Int(c.amount)) (\(c.count))") }
        case "patterns":
            // Which parser pattern read how many messages, and the skip reasons (read-only pass over the SMS).
            let r = SMSReader.read(after: 0)
            var counts: [String: Int] = [:]
            for m in r.messages {
                for item in MessageParser.parse(m) {
                    switch item {
                    case .txn(let t): counts["txn:" + t.pattern, default: 0] += 1
                    case .balance: counts["balance", default: 0] += 1
                    case .brokerBalance: counts["broker-balance", default: 0] += 1
                    case .turnover: counts["turnover", default: 0] += 1
                    case .mandate: counts["mandate", default: 0] += 1
                    case .loanDue: counts["loan-due", default: 0] += 1
                    case .ignored(let why): counts["ignored:" + why, default: 0] += 1
                    }
                }
            }
            log("patterns over \(r.messages.count) business SMS: " + counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        case "unparsed":
            // Bank / payment SMS that nothing understood (to improve the parser). Full text, on this phone only.
            let r = SMSReader.read(after: 0)
            for m in r.messages {
                let info = MessageParser.senderInfo(m.sender)
                guard let code = info.code, MessageParser.bankCodes[code] != nil || MessageParser.financeCodes.contains(code) else { continue }
                let items = MessageParser.parse(m)
                if items.count == 1, case .ignored(let why) = items[0], why == "no pattern" || why == "not a bank or payment sender" {
                    log("unparsed \(m.sender): \(m.text)")
                }
            }
        case "snapshot":
            snapshot(a["name"] ?? "snap")
        case "tab":
            router.showSplash = false
            router.tab = MainTab(rawValue: a["name"] ?? "expenses") ?? .expenses
        case "chart":
            Pref.d.set(a["kind"] ?? "daily", forKey: Pref.chartKind)
        case "tradechart":
            Pref.d.set(a["kind"] ?? "daily", forKey: Pref.tradeChartKind)
        case "checkin":
            router.showCheckin = a["show"] != "0"
        case "mantra":
            router.showMantra = a["show"] != "0"
        case "splash":
            router.showSplash = a["show"] != "0"
        case "budgets":
            router.showBudgets = a["show"] != "0"
        case "dismiss":
            router.showCheckin = false; router.showMantra = false; router.showBudgets = false; router.showImport = false
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
                .first { $0.isKeyWindow }?.rootViewController?.dismiss(animated: false)
        case "scroll":
            log("scroll is not supported; use tab/chart")
        case "listenertest":
            Reminders.postListenerTest()
        case "reminder":
            Reminders.refresh(store: store)
            UNUserNotificationCenterProbe.dump()
        case "lookup":
            let name = a["name"] ?? ""
            Task {
                let ans = await FreeLookup(city: Pref.d.string(forKey: Pref.lookupCity) ?? "").lookup(name)
                log("lookup \(name) -> \(ans.map { "\($0.category ?? "-") confident=\($0.confident) person=\($0.person) name=\($0.name ?? "-") note=\($0.note ?? "-")" } ?? "nothing")")
            }
        case "setcity":
            Pref.d.set(a["name"] ?? "", forKey: Pref.lookupCity)
            log("city=\(a["name"] ?? "")")
        case "ocr":
            guard let p = a["path"], let img = UIImage(contentsOfFile: p) else { log("ocr: no image"); return }
            Task {
                let lines = await ScreenshotScanner.recognize(img)
                for l in lines { log(String(format: "ocr y=%.3f x=%.3f h=%.3f tint=%d %@", l.y, l.x, l.h, l.tint, l.text)) }
                let r = TradeOCRParser.read(lines)
                log("reading broker=\(r.broker ?? "-") kind=\(r.kind.rawValue) total=\(r.total.map { String($0) } ?? "-") current=\(r.currentValue.map { String($0) } ?? "-") conf=\(r.confidence) rows=\(r.positions.count) notes=\(r.notes)")
            }
        case "holiday":
            let d = a["date"].flatMap { Cal.fromDayKey($0) } ?? Date()
            log("holiday \(Cal.dayKey(d)) trading=\(Holidays.isTradingDay(d, extra: store.state.userHolidays)) status=\(Holidays.marketStatus(at: d, extra: store.state.userHolidays))")
        default:
            log("unknown command")
        }
    }

    @MainActor
    static func snapshot(_ name: String) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }.filter { !$0.isHidden }.sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
        guard let key = windows.first(where: { $0.isKeyWindow }) ?? windows.first else { log("snapshot: no window"); return }
        let r = UIGraphicsImageRenderer(bounds: key.bounds)
        let img = r.image { _ in for w in windows { w.drawHierarchy(in: w.frame, afterScreenUpdates: true) } }
        let u = Paths.caches.appendingPathComponent("kb-snap-\(name).png")
        try? img.pngData()?.write(to: u)
        log("snapshot \(u.lastPathComponent) \(Int(key.bounds.width))x\(Int(key.bounds.height))")
    }
}

enum UNUserNotificationCenterProbe {
    static func dump() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { reqs in
            for r in reqs {
                let when = (r.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate().map { Cal.fullFormatter.string(from: $0) } ?? "-"
                Diag.log("pending \(r.identifier) next=\(when) body=\(r.content.body)")
            }
        }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            Diag.log("notification auth=\(s.authorizationStatus.rawValue) badge=\(s.badgeSetting.rawValue)")
        }
    }
}
