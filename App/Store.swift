import Foundation
import SwiftUI
import UIKit

/// The app's state: the ledger plus everything that feeds it. Main-actor; heavy reading happens off the main thread.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var ledger: Ledger
    @Published var syncing = false
    @Published var status: String?
    @Published var lastReport: IngestReport?
    @Published var lookingUp = false
    @Published var lookupStatus: String?
    @Published var loadProblem: String?

    let db: MerchantDB
    private var saveItem: DispatchWorkItem?
    private let io = DispatchQueue(label: "kubera.io", qos: .utility)

    init() {
        let db = MerchantDB.load()
        self.db = db
        var state = LedgerState()
        var problem: String?
        if let data = try? Data(contentsOf: Paths.ledger) {
            do {
                state = try JSONDecoder().decode(LedgerState.self, from: data)
            } catch {
                // Never overwrite a file we could not read: keep it aside and start empty.
                let stamp = Int(Date().timeIntervalSince1970)
                let aside = Paths.support.appendingPathComponent("kubera.unreadable-\(stamp).json")
                try? FileManager.default.moveItem(at: Paths.ledger, to: aside)
                problem = "The saved data could not be read and was kept aside as \(aside.lastPathComponent)."
            }
        }
        ledger = Ledger(state: state, db: db)
        loadProblem = problem
    }

    var state: LedgerState { ledger.state }
    var categories: [Category] { ledger.categories }

    func category(_ id: String) -> Category {
        categories.first { $0.id == id }
            ?? (id == "other" ? Category(id: "other", name: "Other", symbol: "ellipsis.circle.fill", colorHex: "#9E9E9E", kind: .expense)
                : Category(id: id, name: id.capitalized, symbol: "tag.fill", colorHex: "#9E9E9E", kind: .expense))
    }

    var spend: SpendStats { SpendStats(txns: ledger.state.txns, categories: categories) }
    var uncategorized: [Txn] { ledger.uncategorized }
    var allHolidays: [Holiday] { Holidays.builtIn + ledger.state.userHolidays }

    // MARK: Saving

    /// Bumped by every change, so a background ingest knows whether its copy is still current.
    private var version = 0

    func mutate(_ change: (inout Ledger) -> Void) {
        change(&ledger)
        version += 1
        scheduleSave()
    }

    func scheduleSave() {
        saveItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.saveNow() }
        }
        saveItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    func saveNow() {
        saveItem?.cancel()
        guard let data = try? JSONEncoder().encode(ledger.state) else { return }
        io.async {
            try? data.write(to: Paths.ledger, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    // MARK: Sync

    /// Reads new SMS, notification-inbox lines and (if set up) Gmail, then sorts what came in.
    func sync(reason: String) async {
        guard !syncing else { return }
        syncing = true
        status = "Reading messages…"
        defer { syncing = false }
        let smsOn = Pref.d.bool(forKey: Pref.smsEnabled)
        let inboxOn = Pref.d.bool(forKey: Pref.inboxEnabled)
        let lastRow = ledger.state.lastSMSRowID
        let offsets = ledger.state.inboxOffsets

        let (sms, inbox) = await withCheckedContinuation { (cont: CheckedContinuation<(SMSReader.Result?, NotificationInbox.Result?), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let s = smsOn ? SMSReader.read(after: lastRow) : nil
                let n = inboxOn ? NotificationInbox.read(offsets: offsets) : nil
                cont.resume(returning: (s, n))
            }
        }
        var messages: [RawMessage] = []
        var notes: [String] = []
        if let s = sms {
            if let e = s.error { notes.append(e) }
            messages += s.messages
        }
        if let n = inbox { messages += n.messages }

        var mailMessages: [RawMessage] = []
        if Pref.d.bool(forKey: Pref.mailEnabled) {
            let last = Pref.d.double(forKey: Pref.lastMailSync)
            if reason == "manual" || Date().timeIntervalSince1970 - last > 1800 {
                status = "Reading Gmail…"
                do {
                    mailMessages = try await MailSync.fetch(state: ledger.state)
                    Pref.d.set(Date().timeIntervalSince1970, forKey: Pref.lastMailSync)
                } catch {
                    notes.append("Gmail: \(error.localizedDescription)")
                }
            }
        }

        // Parsing hundreds of messages takes a moment: do it on a copy off the main thread, then swap it in
        // (or redo it here if something was edited meanwhile, so that edit is kept).
        let all = messages + mailMessages
        let work: (inout Ledger) -> IngestReport = { l in
            if let s = sms, s.error == nil { l.state.lastSMSRowID = s.maxRowID }
            if let n = inbox { l.state.inboxOffsets = n.offsets }
            let r = l.ingest(all)
            l.snapshotIfNeeded()
            return r
        }
        let before = version
        let copy = ledger
        let (done, bgReport) = await withCheckedContinuation { (cont: CheckedContinuation<(Ledger, IngestReport), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var l = copy
                let r = work(&l)
                cont.resume(returning: (l, r))
            }
        }
        var report = bgReport
        if version == before {
            ledger = done
            version += 1
            scheduleSave()
        } else {
            mutate { l in report = work(&l) }
        }
        lastReport = report
        status = notes.isEmpty ? (report.added > 0 ? "\(report.added) new · \(uncategorized.count) to sort" : "Up to date") : notes.joined(separator: "\n")
        Diag.log("sync(\(reason)) msgs=\(report.messages) added=\(report.added) dup=\(report.duplicates) bal=\(report.balances) ignored=\(report.ignored) other=\(report.other) unsorted=\(uncategorized.count) notes=\(notes)")
        Reminders.refresh(store: self)
        Reminders.checkBudgets(store: self, newIDs: report.addedIDs)
        if !report.lookups.isEmpty || ledger.state.txns.contains(where: { $0.lookupState == .pending }) {
            Task { await self.runLookups(useClaude: false) }
        }
    }

    // MARK: Lookups

    /// Free lookups for unknown businesses; then Claude (if switched on, at most once an hour unless asked).
    func runLookups(useClaude: Bool) async {
        guard !lookingUp else { return }
        lookingUp = true
        defer { lookingUp = false }
        let city = Pref.d.string(forKey: Pref.lookupCity) ?? ""
        var pending: [String: String] = [:]   // key -> name
        for t in ledger.state.txns where t.lookupState == .pending && !t.isDuplicate && t.category == Category.uncategorized {
            if pending[t.counterpartyKey] == nil { pending[t.counterpartyKey] = t.counterparty }
        }
        if Pref.d.bool(forKey: Pref.webLookup) && !pending.isEmpty {
            let free = FreeLookup(city: city)
            var n = 0
            for (key, name) in pending.prefix(25) {
                n += 1
                lookupStatus = "Looking up \(name) (\(n)/\(min(25, pending.count)))"
                if let a = await free.lookup(name) {
                    mutate { $0.applyLookup(key: key, category: a.category, confident: a.confident, note: a.note, source: .web, person: a.person, name: a.name) }
                    pending[key] = nil
                } else {
                    mutate { $0.markLookup(key: key, state: .failed) }
                }
                try? await Task.sleep(nanoseconds: 1_100_000_000) // OpenStreetMap allows one request a second
            }
        }
        let claudeOn = Pref.d.bool(forKey: Pref.claudeEnabled)
        let lastClaude = Pref.d.double(forKey: Pref.lastClaudeRun)
        if claudeOn, useClaude || Date().timeIntervalSince1970 - lastClaude > 3600, let key = Keychain.get(Keychain.claudeKey), !key.isEmpty {
            await runClaude(apiKey: key, city: city)
        }
        lookupStatus = nil
        Reminders.refresh(store: self)
    }

    private func runClaude(apiKey: String, city: String) async {
        var items: [ClaudeLookup.Item] = []
        var seen = Set<String>()
        for t in uncategorized where !t.isPerson && !t.counterpartyKey.isEmpty && !seen.contains(t.counterpartyKey) {
            guard Categorizer.isLookupable(name: t.counterparty, vpa: t.vpa) else { continue }
            seen.insert(t.counterpartyKey)
            items.append(.init(key: t.counterpartyKey, name: t.counterparty))
            if items.count >= 25 { break }
        }
        guard !items.isEmpty else { return }
        lookupStatus = "Asking Claude about \(items.count) payee\(items.count == 1 ? "" : "s")…"
        let model = Pref.d.string(forKey: Pref.claudeModel) ?? "claude-opus-5-5"
        let c = ClaudeLookup(apiKey: apiKey, model: model, city: city, categories: categories)
        do {
            let results = try await c.categorize(items)
            Pref.d.set(Date().timeIntervalSince1970, forKey: Pref.lastClaudeRun)
            mutate { l in
                for r in results {
                    let person = r.category == Category.people
                    l.applyLookup(key: r.key, category: person ? nil : r.category, confident: r.confidence == "high",
                                  note: "Claude: " + r.reason, source: .claude, person: person, name: r.display_name)
                }
            }
            Diag.log("claude ok \(results.count) results")
        } catch {
            lookupStatus = error.localizedDescription
            Diag.log("claude failed \(error.localizedDescription)")
        }
    }

    // MARK: Editing

    func setCategory(_ t: Txn, _ category: String, remember: Bool, label: String? = nil) {
        mutate { $0.setCategory(t.id, category: category, remember: remember, label: label) }
        Reminders.refresh(store: self)
    }

    func update(_ t: Txn) {
        mutate { l in
            if let i = l.state.txns.firstIndex(where: { $0.id == t.id }) { l.state.txns[i] = t }
        }
        Reminders.refresh(store: self)
    }

    func addManual(_ t: Txn) {
        mutate { l in
            l.state.txns.append(t)
            l.state.txns.sort { $0.date < $1.date }
        }
    }

    func delete(_ t: Txn) {
        mutate { l in l.state.txns.removeAll { $0.id == t.id } }
    }

    func setBudget(_ category: String, _ amount: Double?) {
        mutate { $0.state.budgets[category] = (amount ?? 0) > 0 ? amount : nil }
    }

    func saveTrade(_ d: TradeDay) {
        mutate { $0.upsertTrade(d) }
    }

    func deleteTrade(_ d: TradeDay) {
        mutate { $0.state.trades[d.id] = nil }
    }

    func saveManual(_ m: ManualItem) {
        mutate { l in
            if let i = l.state.manual.firstIndex(where: { $0.id == m.id }) { l.state.manual[i] = m } else { l.state.manual.append(m) }
        }
    }

    func deleteManual(_ m: ManualItem) {
        mutate { $0.state.manual.removeAll { $0.id == m.id } }
    }

    func updateBalance(_ b: AccountBalance) {
        mutate { $0.state.balances[b.id] = b }
    }

    func addCategory(_ c: Category) {
        mutate { $0.state.customCategories.append(c) }
    }

    func addHoliday(_ h: Holiday) {
        mutate { $0.state.userHolidays.append(h) }
    }

    func removeHoliday(_ h: Holiday) {
        mutate { $0.state.userHolidays.removeAll { $0.id == h.id } }
    }

    func removeRule(_ key: String) {
        mutate { $0.removeRule(key) }
    }

    func markSeenAssets(_ ids: [String]) {
        mutate { l in
            l.state.seenAssets.append(contentsOf: ids)
            if l.state.seenAssets.count > 3000 { l.state.seenAssets.removeFirst(l.state.seenAssets.count - 3000) }
            l.state.lastScreenshotScan = Date()
        }
    }

    /// Starts again from the first SMS (keeps your categories: transactions already known are skipped by id).
    func rescanSMS() async {
        mutate { $0.state.lastSMSRowID = 0 }
        await sync(reason: "manual")
    }

    // MARK: Export

    func exportCSV() -> URL? {
        var rows = ["Date,Amount,Direction,Category,Payee,UPI ID,Instrument,Bank,Account,Reference,Source,Note"]
        let f = ISO8601DateFormatter()
        f.timeZone = Cal.ist
        for t in ledger.state.txns where !t.isDuplicate {
            let cells = [f.string(from: t.date), String(format: "%.2f", t.amount), t.direction.rawValue, category(t.category).name,
                         t.counterparty, t.vpa ?? "", t.instrument.label, t.bank ?? "", t.last4 ?? "", t.ref ?? "", t.source.label, t.note ?? ""]
            rows.append(cells.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ","))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Kubera-\(Cal.dayKey(Date())).csv")
        do { try rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
    }

    func exportBackup() -> URL? {
        guard let data = try? JSONEncoder().encode(ledger.state) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Kubera-backup-\(Cal.dayKey(Date())).json")
        do { try data.write(to: url); return url } catch { return nil }
    }

    func restoreBackup(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let st = try? JSONDecoder().decode(LedgerState.self, from: data) else { return false }
        _ = exportBackup() // the current data, kept in tmp just in case
        ledger = Ledger(state: st, db: db)
        saveNow()
        return true
    }
}

/// Gmail over IMAP (optional; address + app password in Settings).
enum MailSync {
    static func fetch(state: LedgerState) async throws -> [RawMessage] {
        guard let address = Pref.d.string(forKey: Pref.mailAddress), !address.isEmpty,
              let password = Keychain.get(Keychain.gmailPassword), !password.isEmpty else { return [] }
        let client = GmailIMAPClient(email: address, appPassword: password)
        let since = Cal.addMonths(-6, to: Cal.startOfMonth(Date()))
        let query = GmailIMAPClient.defaultAlertQuery(since: since)
        let sameValidity = state.mailUIDValidity != 0
        let r = try await client.fetch(query: query, sinceUID: sameValidity ? state.mailHighestUID : nil,
                                       uidValidity: sameValidity ? state.mailUIDValidity : nil, limit: 400)
        await MainActor.run {
            Store.shared.mutate { l in
                l.state.mailUIDValidity = r.uidValidity
                l.state.mailHighestUID = max(l.state.mailHighestUID, r.highestUID)
            }
        }
        return r.messages.map { m in
            RawMessage(id: "mail:\(r.uidValidity):\(m.uid)", date: m.date ?? Date(), sender: m.from,
                       text: m.subject + " · " + m.text.prefix(1500), source: .email)
        }
    }
}
