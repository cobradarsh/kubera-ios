import SwiftUI
import Charts

struct NetWorthView: View {
    @EnvironmentObject var store: Store
    @State private var editing: ManualItem?
    @State private var editingBalance: AccountBalance?

    var body: some View {
        let nw = store.ledger.netWorth()
        let accounts = store.state.balances.values.sorted { $0.balance > $1.balance }
        let assets = store.state.manual.filter { !$0.kind.isLiability }.sorted { $0.value > $1.value }
        let liabilities = store.state.manual.filter { $0.kind.isLiability }.sorted { $0.value > $1.value }
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    MantraHeader()
                    VStack(spacing: 6) {
                        Text("My Net Worth").font(.caption).foregroundColor(Theme.dim)
                        Text(Money.format(nw.net, paise: false))
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.goldGradient)
                            .monospacedDigit()
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        Text("\(Money.compact(nw.totalAssets)) owned − \(Money.compact(nw.liabilities)) owed").font(.footnote).foregroundColor(Theme.dim)
                        if let change = monthChange(nw.net) {
                            Text("\(Money.signed(change)) since the 1st").font(.footnote.weight(.semibold)).foregroundColor(Theme.pnl(change))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .card(padding: 18)

                    breakdown(nw)
                    history(nw)

                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(title: "Read from SMS", trailing: "tap to rename or leave out")
                        if accounts.isEmpty {
                            Text("Bank balances appear after the first \"Available Bal\" or balance SMS; broker balances after NSE's weekly fund-balance SMS.")
                                .font(.footnote).foregroundColor(Theme.dim)
                        }
                        ForEach(accounts) { a in
                            Button { editingBalance = a } label: {
                                HStack {
                                    Image(systemName: a.kind == .broker ? "chart.bar.fill" : "building.columns.fill").foregroundColor(Theme.gold).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(a.title).font(.subheadline)
                                        Text("\(a.kind.label) · as of \(Cal.dayMonthFormatter.string(from: a.asOf))").font(.caption2).foregroundColor(Theme.faint)
                                    }
                                    Spacer()
                                    Text(Money.format(a.balance, paise: false)).font(.subheadline.weight(.semibold)).monospacedDigit()
                                        .strikethrough(!a.includeInNetWorth)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .card()

                    itemSection("Assets", items: assets, addKind: .stocks)
                    itemSection("Liabilities", items: liabilities, addKind: .loan)
                    if !store.state.loans.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionTitle(title: "Loan EMIs seen in SMS")
                            ForEach(Array(store.state.loans.values), id: \.lender) { l in
                                HStack {
                                    Text(l.lender).font(.subheadline)
                                    Spacer()
                                    Text("\(Money.format(l.emi, paise: false))/month · next \(Cal.dayMonthFormatter.string(from: l.nextDue))").font(.caption).foregroundColor(Theme.dim)
                                }
                            }
                            Text("Add the outstanding amount under Liabilities to count it.").font(.caption2).foregroundColor(Theme.faint)
                        }
                        .card()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .kuberaScreen()
            .navigationTitle("Net Worth")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editing) { m in ManualItemEditor(item: m) }
            .sheet(item: $editingBalance) { b in BalanceEditor(balance: b) }
        }
    }

    /// Change since the 1st, from the balance history (nil before the first full month of history).
    private func monthChange(_ now: Double) -> Double? {
        let first = Cal.startOfMonth(Date())
        guard let s = store.ledger.netWorthHistory().first(where: { Cal.sameDay($0.date, first) }) else { return nil }
        return now - s.net
    }

    private func breakdown(_ nw: Ledger.NetWorth) -> some View {
        var parts: [(String, Double, Color)] = [
            ("Bank", nw.bank, Color(hex: "#29B6F6")),
            ("Trading accounts", nw.broker, Theme.gold),
        ]
        var byKind: [AssetKind: Double] = [:]
        for m in store.state.manual where !m.kind.isLiability { byKind[m.kind, default: 0] += m.value }
        let palette = ["#66BB6A", "#AB47BC", "#FF7043", "#FFCA28", "#8D6E63", "#26C6DA", "#EC407A", "#9CCC65", "#7E57C2", "#BDBDBD"]
        for (i, kv) in byKind.sorted(by: { $0.value > $1.value }).enumerated() {
            parts.append((kv.key.label, kv.value, Color(hex: palette[i % palette.count])))
        }
        let shown = parts.filter { $0.1 > 0 }
        let slices = shown.map { DonutSlice(id: $0.0, value: $0.1, color: $0.2, label: $0.0) }
        let total = shown.reduce(0) { $0 + $1.1 }
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "What you own")
            if slices.isEmpty {
                Text("Nothing yet: balances come in from SMS; add investments, gold, property or deposits below.").font(.footnote).foregroundColor(Theme.dim)
            } else {
                DonutChart(slices: slices) {
                    VStack(spacing: 2) {
                        Text(Money.compact(total)).font(.system(.title3, design: .rounded).weight(.bold)).foregroundStyle(Theme.goldGradient)
                        Text("assets").font(.caption2).foregroundColor(Theme.dim)
                    }
                }
                .frame(height: 180)
                ForEach(slices) { s in LegendRow(color: s.color, label: s.label, value: Money.compact(s.value), share: total > 0 ? s.value / total : nil) }
            }
        }
        .card()
    }

    private func history(_ nw: Ledger.NetWorth) -> some View {
        struct P: Identifiable { var id: String; var date: Date; var value: Double }
        let points = store.ledger.netWorthHistory().enumerated().map { i, s in P(id: "\(i)", date: s.date, value: s.net) }
        return VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Over time", trailing: "on the 1st of each month, and today")
            Text("Bank and broker balances as the SMS reported them on each date; your own items at today's value.")
                .font(.caption2).foregroundColor(Theme.faint)
            if points.count < 2 {
                Text("The line starts once there is a full month of balance messages.").font(.footnote).foregroundColor(Theme.dim)
            } else {
                Chart(points) { p in
                    LineMark(x: .value("Date", p.date), y: .value("Net worth", p.value))
                        .foregroundStyle(Theme.gold).interpolationMethod(.monotone).lineStyle(StrokeStyle(lineWidth: 2.5))
                    PointMark(x: .value("Date", p.date), y: .value("Net worth", p.value)).foregroundStyle(Theme.goldLight).symbolSize(25)
                }
                .chartYAxis { AxisMarks { v in AxisGridLine().foregroundStyle(Theme.stroke); AxisValueLabel { Text(Money.compact(v.as(Double.self) ?? 0)) } } }
                .frame(height: 180)
            }
        }
        .card()
    }

    private func itemSection(_ title: String, items: [ManualItem], addKind: AssetKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(title: title, trailing: Money.compact(items.reduce(0) { $0 + $1.value }))
                Button { editing = ManualItem(name: "", kind: addKind, value: 0) } label: {
                    Image(systemName: "plus.circle.fill").font(.title3).foregroundColor(Theme.gold)
                }
            }
            if items.isEmpty {
                Text(title == "Assets" ? "Stocks, mutual funds, FDs, gold, PF, property…" : "Loans, credit card dues, money owed…")
                    .font(.footnote).foregroundColor(Theme.dim)
            }
            ForEach(items) { m in
                Button { editing = m } label: {
                    HStack {
                        Image(systemName: m.kind.symbol).foregroundColor(m.kind.isLiability ? Theme.loss : Theme.gold).frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.name).font(.subheadline)
                            Text(m.kind.label + " · updated " + Cal.dayMonthFormatter.string(from: m.updated)).font(.caption2).foregroundColor(Theme.faint)
                        }
                        Spacer()
                        Text(Money.format(m.value, paise: false)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .card()
    }
}

struct ManualItemEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let original: ManualItem
    @State private var name: String
    @State private var kind: AssetKind
    @State private var value: String
    @State private var note: String

    init(item: ManualItem) {
        original = item
        _name = State(initialValue: item.name)
        _kind = State(initialValue: item.kind)
        _value = State(initialValue: item.value == 0 ? "" : String(format: "%.0f", item.value))
        _note = State(initialValue: item.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. HDFC FD, Gold coins, Home loan)", text: $name)
                    Picker("Type", selection: $kind) {
                        ForEach(AssetKind.allCases) { k in Label(k.label, systemImage: k.symbol).tag(k) }
                    }
                    TextField("Value ₹", text: $value).keyboardType(.decimalPad)
                    TextField("Note", text: $note)
                } footer: {
                    Text(kind.isLiability ? "Counted as money you owe." : "Counted as money you own.")
                }
                Section {
                    Button("Save") {
                        var m = original
                        m.name = name.trimmed.isEmpty ? kind.label : name.trimmed
                        m.kind = kind
                        m.value = abs(Money.parse(value) ?? 0)
                        m.note = note.trimmed.isEmpty ? nil : note
                        m.updated = Date()
                        store.saveManual(m)
                        dismiss()
                    }
                    .disabled(Money.parse(value) == nil)
                    if store.state.manual.contains(where: { $0.id == original.id }) {
                        Button("Delete", role: .destructive) { store.deleteManual(original); dismiss() }
                    }
                }
            }
            .kuberaScreen()
            .navigationTitle(original.name.isEmpty ? "Add" : original.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct BalanceEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var balance: AccountBalance

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nickname", text: Binding(get: { balance.nickname ?? "" }, set: { balance.nickname = $0.isEmpty ? nil : $0 }))
                    Toggle("Count in net worth", isOn: $balance.includeInNetWorth).tint(Theme.gold)
                    HStack { Text("Balance"); Spacer(); Text(Money.format(balance.balance)).monospacedDigit() }
                    HStack { Text("As of"); Spacer(); Text(Cal.fullFormatter.string(from: balance.asOf)).foregroundColor(Theme.dim) }
                } footer: { Text("Updated automatically from the bank's balance messages.") }
                if balance.history.count > 1 {
                    Section("History") {
                        Chart(balance.history.suffix(90), id: \.date) { p in
                            LineMark(x: .value("Date", p.date), y: .value("Balance", p.balance)).foregroundStyle(Theme.gold)
                        }
                        .chartYAxis { AxisMarks { v in AxisValueLabel { Text(Money.compact(v.as(Double.self) ?? 0)) } } }
                        .frame(height: 160)
                    }
                }
            }
            .kuberaScreen()
            .navigationTitle(balance.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Save") { store.updateBalance(balance); dismiss() } }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
