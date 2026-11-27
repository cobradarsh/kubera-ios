import SwiftUI

struct TransactionsView: View {
    @EnvironmentObject var store: Store
    var filterCategory: String? = nil
    @State private var query = ""
    @State private var showCredits = true
    @State private var showDuplicates = false

    var body: some View {
        let items = filtered
        let groups = Dictionary(grouping: items) { Cal.startOfDay($0.date) }.sorted { $0.key > $1.key }
        List {
            if items.isEmpty {
                EmptyNote(symbol: "magnifyingglass", title: "Nothing here", detail: "Try another search.")
                    .listRowBackground(Color.clear)
            }
            ForEach(groups, id: \.key) { group in
                let day = group.key
                let list = group.value
                Section {
                    ForEach(list.sorted { $0.date > $1.date }) { t in
                        NavigationLink(value: t) { TxnRow(txn: t) }
                            .listRowBackground(Theme.card)
                    }
                } header: {
                    HStack {
                        Text(Cal.dayTitleFormatter.string(from: day))
                        Spacer()
                        let spent = store.spend.spent(list)
                        if spent > 0 { Text(Money.format(spent, paise: false)).monospacedDigit() }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.dim)
                }
            }
        }
        .listStyle(.insetGrouped)
        .kuberaScreen()
        .searchable(text: $query, prompt: "Payee, amount, UPI ID, note")
        .navigationTitle(filterCategory.map { store.category($0).name } ?? "Transactions")
        .toolbar {
            Menu {
                Toggle("Money received", isOn: $showCredits)
                Toggle("Hidden repeats", isOn: $showDuplicates)
            } label: { Image(systemName: "line.3.horizontal.decrease.circle").foregroundColor(Theme.gold) }
        }
    }

    private var filtered: [Txn] {
        let q = query.trimmed.lowercased()
        return store.state.txns.filter { t in
            if !showDuplicates && t.isDuplicate { return false }
            if !showCredits && t.direction == .credit { return false }
            if let c = filterCategory, t.category != c { return false }
            if q.isEmpty { return true }
            return t.counterparty.lowercased().contains(q) || (t.vpa?.lowercased().contains(q) ?? false)
                || String(format: "%.0f", t.amount).contains(q) || (t.note?.lowercased().contains(q) ?? false)
                || store.category(t.category).name.lowercased().contains(q)
        }
    }
}

/// One transaction: category, note, rule, and where it came from.
struct TxnDetailView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let txn: Txn
    @State private var current: Txn
    @State private var remember = true
    @State private var name = ""
    @State private var note = ""
    @State private var showRaw = false

    init(txn: Txn) {
        self.txn = txn
        _current = State(initialValue: txn)
        _name = State(initialValue: txn.counterparty)
        _note = State(initialValue: txn.note ?? "")
    }

    var body: some View {
        let cat = store.category(current.category)
        ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 8) {
                    CategoryIcon(category: cat, size: 60)
                    Text((current.direction == .credit ? "+" : "") + Money.format(current.amount))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(current.direction == .credit ? Theme.profit : Theme.text)
                    Text(Cal.fullFormatter.string(from: current.date)).font(.footnote).foregroundColor(Theme.dim)
                    HStack(spacing: 6) {
                        Pill(text: cat.name, color: Color(hex: cat.colorHex))
                        Pill(text: current.categorySource.label, color: Theme.dim)
                    }
                }
                .frame(maxWidth: .infinity)
                .card(padding: 18)

                VStack(alignment: .leading, spacing: 10) {
                    TextField("Payee name", text: $name)
                        .font(.headline)
                        .textInputAutocapitalization(.words)
                    if let s = current.suggestionNote { Text(s).font(.caption).foregroundColor(Theme.dim) }
                    Toggle(isOn: $remember) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Remember for this payee").font(.subheadline)
                            Text(current.counterpartyKey.isEmpty ? "No stable name to remember" : "Future payments to the same \(current.vpa != nil ? "UPI ID" : "name") get the same category")
                                .font(.caption2).foregroundColor(Theme.dim)
                        }
                    }
                    .tint(Theme.gold)
                    .disabled(current.counterpartyKey.isEmpty)
                }
                .card()

                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(title: "Category")
                    CategoryGrid(selected: current.category, suggestion: current.suggestion) { id in
                        Haptic.success()
                        store.setCategory(current, id, remember: remember, label: name == current.counterparty ? nil : name)
                        if let t = store.state.txns.first(where: { $0.id == current.id }) { current = t }
                    }
                }
                .card()

                VStack(alignment: .leading, spacing: 10) {
                    TextField("Note", text: $note, axis: .vertical).lineLimit(1...4)
                    Toggle("Leave out of all totals", isOn: Binding(get: { current.excluded }, set: { v in
                        current.excluded = v
                        store.update(current)
                    }))
                    .tint(Theme.gold)
                }
                .card()

                VStack(alignment: .leading, spacing: 6) {
                    info("Paid with", current.instrument.label + (current.last4.map { " ••\($0)" } ?? ""))
                    if let b = current.bank { info("Bank", b) }
                    if let v = current.vpa { info("UPI ID", v) }
                    if let r = current.ref { info("Reference", r) }
                    if let b = current.balanceAfter { info("Balance after", Money.format(b)) }
                    info("Source", current.source.label + (current.sender.map { " · \($0)" } ?? ""))
                    if current.isDuplicate { info("Shown as", "a repeat of another message (hidden from totals)") }
                    Button(showRaw ? "Hide the message" : "Show the message") { showRaw.toggle() }.font(.footnote).foregroundColor(Theme.gold)
                    if showRaw {
                        Text(current.raw).font(.caption.monospaced()).foregroundColor(Theme.dim).textSelection(.enabled)
                    }
                }
                .card()

                if current.source == .manual {
                    Button(role: .destructive) { store.delete(current); dismiss() } label: {
                        Label("Delete", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(16)
        }
        .kuberaScreen()
        .navigationTitle(name.isEmpty ? "Payment" : name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            var t = store.state.txns.first(where: { $0.id == current.id }) ?? current
            let newNote = note.trimmed.isEmpty ? nil : note.trimmed
            var changed = false
            if t.note != newNote { t.note = newNote; changed = true }
            if name.trimmed != t.counterparty && !name.trimmed.isEmpty { t.counterparty = name.trimmed; changed = true }
            if changed { store.update(t) }
        }
    }

    private func info(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.caption).foregroundColor(Theme.dim).frame(width: 96, alignment: .leading)
            Text(v).font(.caption).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

/// All categories as tappable tiles; the suggested one is outlined.
struct CategoryGrid: View {
    @EnvironmentObject var store: Store
    var selected: String?
    var suggestion: String?
    var kinds: [CategoryKind] = [.expense, .investment, .transfer, .income]
    var onPick: (String) -> Void

    var body: some View {
        let cats = store.categories.filter { kinds.contains($0.kind) && $0.id != Category.uncategorized }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 10) {
            ForEach(cats) { c in
                Button { onPick(c.id) } label: {
                    VStack(spacing: 5) {
                        CategoryIcon(category: c, size: 40)
                        Text(c.name).font(.system(size: 10, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
                            .minimumScaleFactor(0.8).frame(height: 26, alignment: .top)
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).fill(selected == c.id ? Color(hex: c.colorHex).opacity(0.22) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(suggestion == c.id ? Theme.gold : Color.clear, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct AddTxnView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var payee = ""
    @State private var date = Date()
    @State private var category = "food"
    @State private var isCredit = false
    @State private var instrument: Instrument = .cash

    var body: some View {
        Form {
            Section {
                TextField("Amount (₹)", text: $amount).keyboardType(.decimalPad).font(.title2.weight(.semibold))
                TextField("Paid to / received from", text: $payee)
                DatePicker("When", selection: $date)
                Picker("Type", selection: $isCredit) { Text("Spent").tag(false); Text("Received").tag(true) }.pickerStyle(.segmented)
                Picker("Paid with", selection: $instrument) {
                    ForEach(Instrument.allCases, id: \.self) { i in Text(i.label).tag(i) }
                }
            }
            Section("Category") {
                CategoryGrid(selected: category, suggestion: nil) { category = $0 }
            }
            Section {
                Button("Save") {
                    guard let v = Money.parse(amount), v > 0 else { return }
                    var t = Txn(id: "manual:" + UUID().uuidString, date: date, amount: v, direction: isCredit ? .credit : .debit)
                    t.counterparty = payee.trimmed
                    t.counterpartyKey = Categorizer.key(counterparty: payee, vpa: nil)
                    t.category = category
                    t.categorySource = .user
                    t.instrument = instrument
                    t.source = .manual
                    store.addManual(t)
                    Haptic.success()
                    dismiss()
                }
                .disabled(Money.parse(amount) == nil)
            }
        }
        .kuberaScreen()
        .navigationTitle("Add")
    }
}

/// The 22:00 check-in: each unsorted payment as a card; one tap sorts it (and remembers the payee).
struct CheckInView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var remember = true
    @State private var labels: [String: String] = [:]
    @AppStorage(Pref.claudeEnabled) private var claudeOn = false

    var body: some View {
        NavigationStack {
            let pending = store.uncategorized
            ScrollView {
                VStack(spacing: 14) {
                    MantraHeader()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pending.isEmpty ? "All sorted 🙏" : "\(pending.count) to sort").font(.title3.weight(.bold))
                            Text("Tap a category. Remembered payees sort themselves next time.").font(.caption).foregroundColor(Theme.dim)
                        }
                        Spacer()
                    }
                    Toggle("Remember each choice for the payee", isOn: $remember).tint(Theme.gold).font(.footnote)
                    if store.lookingUp || store.lookupStatus != nil {
                        HStack(spacing: 8) {
                            if store.lookingUp { ProgressView().tint(Theme.gold) }
                            Text(store.lookupStatus ?? "Looking up…").font(.caption).foregroundColor(Theme.dim)
                        }
                    } else if !pending.isEmpty {
                        Button {
                            Task { await store.runLookups(useClaude: true) }
                        } label: {
                            Label(claudeOn ? "Look these up (web + Claude)" : "Look these up on the web", systemImage: "globe.asia.australia.fill")
                                .font(.footnote.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.gold)
                    }
                    ForEach(pending) { t in
                        CheckInCard(txn: t, remember: remember, label: Binding(get: { labels[t.id] ?? "" }, set: { labels[t.id] = $0 }))
                    }
                    if pending.isEmpty {
                        EmptyNote(symbol: "checkmark.seal.fill", title: "Nothing left to sort", detail: "Kubera will remind you again at the check-in time.")
                    }
                }
                .padding(16)
            }
            .kuberaScreen()
            .navigationTitle("Check-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct CheckInCard: View {
    @EnvironmentObject var store: Store
    var txn: Txn
    var remember: Bool
    @Binding var label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(txn.counterparty.isEmpty ? "Unknown payee" : txn.counterparty).font(.headline).lineLimit(2)
                    Text("\(Cal.dayTitleFormatter.string(from: txn.date)), \(Cal.timeFormatter.string(from: txn.date)) · \(txn.instrument.label)")
                        .font(.caption).foregroundColor(Theme.dim)
                    if txn.isPerson { Pill(text: "Looks like a person", color: Color(hex: "#4DB6AC")) }
                    if let n = txn.suggestionNote { Text(n).font(.caption2).foregroundColor(Theme.faint).lineLimit(2) }
                }
                Spacer()
                Text(Money.format(txn.amount)).font(.system(.title3, design: .rounded).weight(.bold)).monospacedDigit()
            }
            TextField(txn.isPerson ? "What was it for? (optional name, e.g. Maid, Milk)" : "Rename (optional)", text: $label)
                .font(.footnote)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.cardRaised))
            if let s = txn.suggestion {
                let c = store.category(s)
                Button {
                    Haptic.success()
                    withAnimation { store.setCategory(txn, s, remember: remember, label: label.trimmed.isEmpty ? nil : label) }
                } label: {
                    HStack {
                        CategoryIcon(category: c, size: 26)
                        Text("Suggested: \(c.name)").font(.footnote.weight(.semibold))
                        Spacer()
                        Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.gold)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).stroke(Theme.gold.opacity(0.6), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            CategoryGrid(selected: nil, suggestion: txn.suggestion, kinds: [.expense, .investment, .transfer]) { id in
                Haptic.success()
                withAnimation { store.setCategory(txn, id, remember: remember, label: label.trimmed.isEmpty ? nil : label) }
            }
        }
        .card()
    }
}

struct BudgetsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]

    var body: some View {
        NavigationStack {
            let month = Date()
            let s = store.spend
            let list = s.inMonth(month)
            Form {
                Section {
                    row(id: "total", name: "Whole month", spent: s.spent(list), symbol: "sum", color: Theme.gold)
                } footer: { Text("Alerts come at 80% and 100% of each budget. Months start on the 1st.") }
                Section("By category") {
                    ForEach(store.categories.filter { $0.kind == .expense && $0.id != Category.uncategorized && $0.id != Category.refunds }) { c in
                        row(id: c.id, name: c.name, spent: s.spent(list.filter { $0.category == c.id }), symbol: c.symbol, color: Color(hex: c.colorHex))
                    }
                }
            }
            .kuberaScreen()
            .navigationTitle("Budgets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { save(); dismiss() } } }
            .onAppear {
                for (k, v) in store.state.budgets { values[k] = String(Int(v)) }
            }
        }
    }

    private func row(id: String, name: String, spent: Double, symbol: String, color: Color) -> some View {
        let budget = Double(values[id] ?? "") ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: symbol).foregroundColor(color).frame(width: 22)
                Text(name)
                Spacer()
                TextField("No budget", text: Binding(get: { values[id] ?? "" }, set: { values[id] = $0.filter { $0.isNumber } }))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
            }
            if budget > 0 {
                ProgressView(value: min(1, spent / budget)).tint(spent > budget ? Theme.loss : color)
                Text("\(Money.format(spent, paise: false)) spent this month").font(.caption2).foregroundColor(Theme.dim)
            }
        }
    }

    private func save() {
        for (k, v) in values { store.setBudget(k, Double(v)) }
    }
}
