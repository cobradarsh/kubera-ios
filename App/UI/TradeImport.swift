import SwiftUI
import UIKit

/// Screenshots found or picked: what was read, editable, then saved as the day's P&L (or holdings value).
struct ScreenshotReviewView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @Binding var findings: [ScreenshotFinding]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if findings.isEmpty {
                        EmptyNote(symbol: "photo.on.rectangle.angled", title: "No screenshots to review",
                                  detail: "Take a screenshot of your broker's positions (or holdings) screen; it shows up here.")
                    }
                    ForEach(findings) { f in
                        FindingCard(finding: f, usualBroker: store.usualBroker) { saved in
                            store.markSeenAssets([f.assetID])
                            findings.removeAll { $0.assetID == f.assetID }
                            if saved { Haptic.success() }
                            if findings.isEmpty { dismiss() }
                        }
                    }
                }
                .padding(16)
            }
            .kuberaScreen()
            .navigationTitle("Broker screenshots")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } } }
        }
    }
}

struct FindingCard: View {
    @EnvironmentObject var store: Store
    let finding: ScreenshotFinding
    var done: (Bool) -> Void
    @State private var day: Date
    @State private var broker: String
    @State private var amount: String
    @State private var charges = ""
    @State private var asHoldings: Bool
    @State private var zoom = false
    @State private var confirmReplace = false

    init(finding: ScreenshotFinding, usualBroker: String, done: @escaping (Bool) -> Void) {
        self.finding = finding
        self.done = done
        _day = State(initialValue: finding.tradingDay)
        // A screen that names no broker the picker knows (or names an analytics app such as Sensibull) starts on the
        // broker most days are saved under; the card says so.
        let read = finding.reading.broker.flatMap { Brokers.all.contains($0) ? $0 : nil }
        _broker = State(initialValue: read ?? usualBroker)
        let r = finding.reading
        let holdings = r.kind == .holdings
        _asHoldings = State(initialValue: holdings)
        let v = holdings ? (r.currentValue ?? r.total ?? 0) : (r.total ?? 0)
        _amount = State(initialValue: v == 0 ? "" : String(format: "%.2f", v))
    }

    var body: some View {
        let r = finding.reading
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(uiImage: finding.image)
                    .resizable().scaledToFit()
                    .frame(width: 96, height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke))
                    .onTapGesture { zoom = true }
                VStack(alignment: .leading, spacing: 6) {
                    Text(r.kind == .holdings ? "Holdings screen" : (r.kind == .positions ? "Positions screen" : "Broker screen")).font(.headline)
                    Text("Taken " + Cal.fullFormatter.string(from: finding.created)).font(.caption).foregroundColor(Theme.dim)
                    Pill(text: String(format: "%.0f%% sure", r.confidence * 100), color: r.confidence >= 0.7 ? Theme.profit : .orange)
                    ForEach(r.notes, id: \.self) { n in Text("• " + n).font(.caption2).foregroundColor(Theme.faint) }
                    ForEach(warnings, id: \.self) { w in Text(w).font(.caption2).foregroundColor(.orange) }
                    if !r.positions.isEmpty {
                        Text("\(r.positions.count) position rows read").font(.caption2).foregroundColor(Theme.dim)
                    }
                }
            }
            Picker("Save as", selection: $asHoldings) {
                Text("Day's P&L").tag(false)
                Text("Holdings value").tag(true)
            }
            .pickerStyle(.segmented)
            if asHoldings {
                TextField("Current value ₹", text: $amount).keyboardType(.decimalPad).font(.title3.weight(.semibold))
                if let inv = r.invested { Text("Invested: \(Money.format(inv, paise: false))").font(.caption).foregroundColor(Theme.dim) }
            } else {
                DatePicker("Trading day", selection: $day, displayedComponents: .date)
                TextField("P&L ₹ (minus for a loss)", text: $amount).keyboardType(.numbersAndPunctuation).font(.title3.weight(.semibold))
                    .foregroundColor(Theme.pnl(Money.parse(amount) ?? 0))
                TextField("Charges ₹ (optional)", text: $charges).keyboardType(.decimalPad)
                if let e = existing {
                    Text("Replaces \(Money.signed(e.pnl)) already saved for \(Cal.dayTitleFormatter.string(from: e.date)) at \(e.broker).")
                        .font(.caption).foregroundColor(.orange)
                }
            }
            Picker("Broker", selection: $broker) {
                ForEach(Brokers.all, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Button("Not a P&L screen") { done(false) }.buttonStyle(.bordered).tint(Theme.dim)
                Spacer()
                Button {
                    if !asHoldings && existing != nil { confirmReplace = true; return }
                    save()
                    done(true)
                } label: { Label("Save", systemImage: "checkmark").frame(minWidth: 90) }
                .buttonStyle(.borderedProminent).tint(Theme.gold).foregroundColor(.black)
                .disabled(Money.parse(amount) == nil)
            }
        }
        .card()
        .sheet(isPresented: $zoom) {
            ScrollView { Image(uiImage: finding.image).resizable().scaledToFit() }.background(Color.black)
        }
        .confirmationDialog("Replace the saved P&L?", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Replace", role: .destructive) { save(); done(true) }
            Button("Keep the saved one", role: .cancel) {}
        } message: {
            if let e = existing { Text("\(Cal.dayTitleFormatter.string(from: e.date)) at \(e.broker) already has \(Money.signed(e.pnl)).") }
        }
    }

    /// A different record already saved for the chosen day and broker.
    private var existing: TradeDay? {
        guard let e = store.state.trades[TradeDay.key(Cal.startOfDay(day), broker)], e.assetId != finding.assetID else { return nil }
        return e
    }

    private var warnings: [String] {
        var w: [String] = []
        let r = finding.reading
        if !finding.dateKnown { w.append("The picture's date was not available: check the trading day.") }
        if let b = r.broker, !Brokers.all.contains(b) {
            w.append("\(b) screen: choose the broker below.")
        } else if r.broker == nil && !asHoldings {
            w.append("Broker not read from the screen: check it below.")
        }
        // A positions screen taken while NSE was open shows a P&L that can still change.
        let mins = Cal.hour(finding.created) * 60 + Cal.cal.component(.minute, from: finding.created)
        if !asHoldings && !r.commodity && Holidays.isTradingDay(finding.created, extra: store.state.userHolidays)
            && mins >= 9 * 60 + 15 && mins < 15 * 60 + 30 {
            w.append("Taken at \(Cal.timeFormatter.string(from: finding.created)), while the market was open: the day's final P&L may differ.")
        }
        return w
    }

    private func save() {
        guard let v = Money.parse(amount) else { return }
        if asHoldings {
            let name = "\(broker) holdings"
            var item = store.state.manual.first { $0.name == name } ?? ManualItem(name: name, kind: .stocks, value: v)
            item.value = abs(v)
            item.updated = finding.created
            item.note = "From a holdings screenshot"
            store.saveManual(item)
        } else {
            let d = Cal.startOfDay(day)
            var t = store.state.trades[TradeDay.key(d, broker)] ?? TradeDay(id: TradeDay.key(d, broker), date: d, broker: broker, pnl: v)
            t.pnl = v
            t.charges = Money.parse(charges) ?? t.charges
            t.positions = finding.reading.positions
            t.source = .screenshot
            t.assetId = finding.assetID
            store.saveTrade(t)
        }
    }
}

struct TradeEditView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let original: TradeDay
    @State private var day: Date
    @State private var broker: String
    @State private var pnl: String
    @State private var charges: String
    @State private var note: String
    @State private var confirmReplace = false

    init(day: TradeDay) {
        original = day
        _day = State(initialValue: day.date)
        _broker = State(initialValue: day.broker)
        _pnl = State(initialValue: day.pnl == 0 ? "" : String(format: "%.2f", day.pnl))
        _charges = State(initialValue: day.charges.map { String(format: "%.2f", $0) } ?? "")
        _note = State(initialValue: day.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Trading day", selection: $day, displayedComponents: .date)
                    Picker("Broker", selection: $broker) {
                        ForEach(Brokers.all.contains(original.broker) ? Brokers.all : [original.broker] + Brokers.all, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("P&L ₹ (minus for a loss)", text: $pnl).keyboardType(.numbersAndPunctuation)
                    TextField("Charges ₹ (brokerage, STT, GST …)", text: $charges).keyboardType(.decimalPad)
                    TextField("Note", text: $note, axis: .vertical)
                } footer: {
                    if !Holidays.isTradingDay(day, extra: store.state.userHolidays) {
                        Text("NSE was closed on this day.").foregroundColor(.orange)
                    }
                }
                if !original.positions.isEmpty {
                    Section("Positions read from the screenshot") {
                        ForEach(original.positions) { p in
                            HStack { Text(p.symbol).font(.caption); Spacer(); AmountText(value: p.pnl, signed: true, paise: false, font: .caption) }
                        }
                    }
                }
                Section {
                    Button("Save") {
                        guard Money.parse(pnl) != nil else { return }
                        if replacing != nil { confirmReplace = true } else { commit() }
                    }
                    .disabled(Money.parse(pnl) == nil)
                    if isStored {
                        Button("Delete this day", role: .destructive) { store.deleteTrade(original); dismiss() }
                    }
                } footer: {
                    if let other = replacing {
                        Text("\(Cal.dayTitleFormatter.string(from: other.date)) at \(other.broker) already has \(Money.signed(other.pnl)) saved; saving replaces it.")
                            .foregroundColor(.orange)
                    }
                }
            }
            .confirmationDialog("Replace the saved P&L?", isPresented: $confirmReplace, titleVisibility: .visible) {
                Button("Replace", role: .destructive) { commit() }
                Button("Cancel", role: .cancel) {}
            }
            .kuberaScreen()
            .navigationTitle("Day's P&L")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private var newKey: String { TradeDay.key(Cal.startOfDay(day), broker) }

    /// Editing a saved record (rather than a new day opened from ✎ or "Traded, no P&L yet").
    private var isStored: Bool { store.state.trades[original.id]?.addedAt == original.addedAt }

    /// Another saved record that saving would overwrite.
    private var replacing: TradeDay? {
        guard let other = store.state.trades[newKey], other.addedAt != original.addedAt else { return nil }
        return other
    }

    private func commit() {
        guard let v = Money.parse(pnl) else { return }
        let d = Cal.startOfDay(day)
        var t = original
        // Moving a saved record to another day or broker takes it off the old one.
        if newKey != original.id && isStored { store.deleteTrade(original) }
        t.id = newKey
        t.date = d
        t.broker = broker
        t.pnl = v
        t.charges = Money.parse(charges)
        t.note = note.trimmed.isEmpty ? nil : note
        store.saveTrade(t)
        Haptic.success()
        dismiss()
    }
}

struct HolidaysView: View {
    @EnvironmentObject var store: Store
    @State private var adding = false
    @State private var newDate = Date()
    @State private var newName = ""
    @State private var newKind: HolidayKind = .nse

    var body: some View {
        let today = Cal.startOfDay(Date())
        let nse = (Holidays.nse2026 + store.state.userHolidays.filter { $0.kind != .india }).sorted { $0.date < $1.date }
        let india = (Holidays.india2026 + store.state.userHolidays.filter { $0.kind == .india }).sorted { $0.date < $1.date }
        List {
            Section {
                HStack {
                    Image(systemName: "chart.line.uptrend.xyaxis.circle.fill").foregroundColor(Theme.gold)
                    Text(Holidays.marketStatus(extra: store.state.userHolidays))
                }
            } footer: {
                Text("NSE equity & F&O. Weekends are always closed. Muhurat trading on Diwali (8 Nov 2026) is a special evening session. NSE publishes the next year's list in December: add its days here when it is out.")
            }
            Section("NSE trading holidays") {
                ForEach(nse) { h in row(h, past: h.date < today) }
            }
            Section("India: gazetted holidays (DoPT)") {
                ForEach(india) { h in row(h, past: h.date < today) }
            }
            Section {
                Button { adding = true } label: { Label("Add a holiday", systemImage: "plus") }
            }
        }
        .listStyle(.insetGrouped)
        .kuberaScreen()
        .navigationTitle("Holidays 2026")
        .sheet(isPresented: $adding) {
            NavigationStack {
                Form {
                    DatePicker("Date", selection: $newDate, displayedComponents: .date)
                    TextField("Name", text: $newName)
                    Picker("List", selection: $newKind) {
                        Text("NSE").tag(HolidayKind.nse)
                        Text("Extra NSE closure").tag(HolidayKind.special)
                        Text("India").tag(HolidayKind.india)
                    }
                }
                .navigationTitle("Add a holiday")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            store.addHoliday(Holiday(date: Cal.startOfDay(newDate), name: newName.trimmed.isEmpty ? "Holiday" : newName.trimmed, kind: newKind))
                            adding = false
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { adding = false } }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func row(_ h: Holiday, past: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(h.name).font(.subheadline)
                Text(Cal.dayTitleFormatter.string(from: h.date) + " " + String(Cal.year(h.date)) + (h.note.map { " · \($0)" } ?? ""))
                    .font(.caption2).foregroundColor(Theme.dim)
            }
            Spacer()
            if h.kind == .special { Pill(text: "extra", color: .orange) }
        }
        .opacity(past ? 0.45 : 1)
        .swipeActions {
            if store.state.userHolidays.contains(h) {
                Button(role: .destructive) { store.removeHoliday(h) } label: { Label("Remove", systemImage: "trash") }
            }
        }
    }
}

enum Brokers {
    /// Brokers the pickers offer.
    static let all = ["Dhan", "Kite", "Kotak Neo", "Upstox", "Groww", "Angel One", "ICICI Direct", "Fyers", "5paisa", "Other"]
}
