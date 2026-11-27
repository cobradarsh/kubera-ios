import SwiftUI
import Charts

enum ExpenseChart: String, CaseIterable, Identifiable {
    case daily, cumulative, donut, categories, weekly, trend, calendar, methods, when, merchants
    var id: String { rawValue }
    var label: String {
        switch self {
        case .daily: return "Daily"
        case .cumulative: return "Running total"
        case .donut: return "Donut"
        case .categories: return "Categories"
        case .weekly: return "Weekly"
        case .trend: return "6 months"
        case .calendar: return "Calendar"
        case .methods: return "Pay mode"
        case .when: return "When"
        case .merchants: return "Top payees"
        }
    }
    var symbol: String {
        switch self {
        case .daily: return "chart.bar.fill"
        case .cumulative: return "chart.line.uptrend.xyaxis"
        case .donut: return "chart.pie.fill"
        case .categories: return "list.bullet.rectangle.fill"
        case .weekly: return "square.stack.3d.up.fill"
        case .trend: return "calendar.badge.clock"
        case .calendar: return "calendar"
        case .methods: return "creditcard.fill"
        case .when: return "clock.fill"
        case .merchants: return "storefront.fill"
        }
    }
}

struct ExpensesView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @State private var month = Cal.startOfMonth(Date())
    @AppStorage(Pref.chartKind) private var chartRaw = ExpenseChart.daily.rawValue

    private var chart: Binding<ExpenseChart> {
        Binding(get: { ExpenseChart(rawValue: chartRaw) ?? .daily }, set: { chartRaw = $0.rawValue })
    }

    var body: some View {
        let s = store.spend
        let list = s.inMonth(month)
        let prev = s.inMonth(Cal.addMonths(-1, to: month))
        NavigationStack(path: $router.expensePath) {
            ScrollView {
                VStack(spacing: 14) {
                    MantraHeader()
                    MonthSwitcher(month: $month)
                    SummaryCard(month: month, list: list, prev: prev)
                    if !store.uncategorized.isEmpty {
                        Button { router.showCheckin = true } label: {
                            HStack {
                                Image(systemName: "tray.full.fill").foregroundColor(.black)
                                Text("\(store.uncategorized.count) to sort").fontWeight(.semibold).foregroundColor(.black)
                                Spacer()
                                Text("Check in").font(.footnote.weight(.semibold)).foregroundColor(.black.opacity(0.7))
                                Image(systemName: "chevron.right").foregroundColor(.black.opacity(0.7))
                            }
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.goldGradient))
                        }
                        .buttonStyle(.plain)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        ChipPicker(items: ExpenseChart.allCases, selection: chart, label: { $0.label }, symbol: { $0.symbol })
                        ExpenseChartView(kind: chart.wrappedValue, month: month, list: list)
                            .frame(minHeight: 240)
                    }
                    .card()
                    CategoryBreakdown(list: list)
                    RecentList(list: list)
                    AccountsStrip()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .refreshable { await store.sync(reason: "manual") }
            .kuberaScreen()
            .navigationTitle("Expenses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if store.syncing { ProgressView().tint(Theme.gold) }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { router.expensePath.append("all") } label: { Label("All transactions", systemImage: "list.bullet") }
                        Button { router.showBudgets = true } label: { Label("Budgets", systemImage: "gauge.medium") }
                        Button { router.expensePath.append("add") } label: { Label("Add an expense", systemImage: "plus") }
                        Button { Task { await store.sync(reason: "manual") } } label: { Label("Read messages now", systemImage: "arrow.clockwise") }
                    } label: { Image(systemName: "ellipsis.circle").foregroundColor(Theme.gold) }
                }
            }
            .navigationDestination(for: String.self) { v in
                switch v {
                case "all": TransactionsView()
                case "add": AddTxnView()
                default: TransactionsView(filterCategory: v)
                }
            }
            .navigationDestination(for: Txn.self) { t in TxnDetailView(txn: t) }
        }
    }
}

struct SummaryCard: View {
    @EnvironmentObject var store: Store
    var month: Date
    var list: [Txn]
    var prev: [Txn]

    var body: some View {
        let s = store.spend
        let spent = s.spent(list)
        let prevSpent = s.spent(prev)
        let income = s.income(list)
        let invested = s.invested(list)
        let isCurrent = Cal.sameMonth(month, Date())
        let daysGone = isCurrent ? max(1, Cal.day(Date())) : Cal.daysInMonth(month)
        let perDay = spent / Double(daysGone)
        let projected = isCurrent ? perDay * Double(Cal.daysInMonth(month)) : spent
        let budget = store.state.budgets["total"]
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spent").font(.caption).foregroundColor(Theme.dim)
                    Text(Money.format(spent, paise: false))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.goldGradient)
                        .monospacedDigit()
                }
                Spacer()
                if prevSpent > 0 {
                    let change = (spent - prevSpent) / prevSpent
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%@%.0f%%", change >= 0 ? "▲ " : "▼ ", abs(change) * 100))
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(change > 0 ? Theme.loss : Theme.profit)
                        Text("vs \(Money.compact(prevSpent)) last month").font(.caption2).foregroundColor(Theme.faint)
                    }
                }
            }
            if let b = budget, b > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: min(1, spent / b))
                        .tint(spent > b ? Theme.loss : (spent > b * 0.8 ? .orange : Theme.gold))
                    Text(spent > b ? "\(Money.format(spent - b, paise: false)) over the \(Money.compact(b)) budget"
                         : "\(Money.format(b - spent, paise: false)) left of \(Money.compact(b))")
                        .font(.caption).foregroundColor(Theme.dim)
                }
            }
            HStack(spacing: 8) {
                StatTile(title: "Per day", value: Money.compact(perDay))
                StatTile(title: isCurrent ? "Projected" : "Month", value: Money.compact(projected))
                StatTile(title: "Income", value: Money.compact(income), color: income > 0 ? Theme.profit : Theme.text)
                StatTile(title: invested >= 0 ? "To trading" : "From trading", value: Money.compact(abs(invested)), color: Theme.gold)
            }
        }
        .card(padding: 16)
    }
}

struct CategoryBreakdown: View {
    @EnvironmentObject var store: Store
    var list: [Txn]
    var body: some View {
        let totals = store.spend.byCategory(list)
        let sum = totals.reduce(0) { $0 + $1.amount }
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "By category", trailing: "\(totals.count) categories")
            if totals.isEmpty {
                EmptyNote(symbol: "sparkles", title: "Nothing spent yet", detail: "Bank SMS appear here as soon as they arrive.")
            }
            ForEach(totals) { t in
                let c = store.category(t.category)
                NavigationLink(value: t.category) {
                    HStack(spacing: 12) {
                        CategoryIcon(category: c, size: 34)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(c.name).font(.subheadline.weight(.medium))
                                Spacer()
                                Text(Money.format(t.amount, paise: false)).font(.subheadline.weight(.semibold)).monospacedDigit()
                            }
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.cardRaised)
                                    Capsule().fill(Color(hex: c.colorHex)).frame(width: max(4, g.size.width * CGFloat(sum > 0 ? t.amount / sum : 0)))
                                }
                            }
                            .frame(height: 5)
                            HStack {
                                Text("\(t.count) payment\(t.count == 1 ? "" : "s")").font(.caption2).foregroundColor(Theme.faint)
                                Spacer()
                                if let b = store.state.budgets[t.category], b > 0 {
                                    Text("\(Int(t.amount / b * 100))% of \(Money.compact(b))").font(.caption2)
                                        .foregroundColor(t.amount > b ? Theme.loss : Theme.faint)
                                } else {
                                    Text(String(format: "%.0f%%", sum > 0 ? t.amount / sum * 100 : 0)).font(.caption2).foregroundColor(Theme.faint)
                                }
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .card()
    }
}

struct RecentList: View {
    @EnvironmentObject var store: Store
    var list: [Txn]
    var body: some View {
        let recent = Array(list.sorted { $0.date > $1.date }.prefix(8))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(title: "Recent")
                NavigationLink(value: "all") { Text("See all").font(.footnote.weight(.semibold)).foregroundColor(Theme.gold) }
            }
            if recent.isEmpty {
                Text("No transactions this month.").font(.footnote).foregroundColor(Theme.dim).padding(.vertical, 8)
            }
            ForEach(recent) { t in
                NavigationLink(value: t) { TxnRow(txn: t) }.buttonStyle(.plain)
                if t.id != recent.last?.id { Divider().background(Theme.stroke) }
            }
        }
        .card()
    }
}

struct TxnRow: View {
    @EnvironmentObject var store: Store
    var txn: Txn
    var body: some View {
        let c = store.category(txn.category)
        HStack(spacing: 12) {
            CategoryIcon(category: c, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(txn.counterparty.isEmpty ? "Unknown payee" : txn.counterparty).font(.subheadline.weight(.medium)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(Cal.timeFormatter.string(from: txn.date))
                    Text("·")
                    Image(systemName: txn.instrument.symbol)
                    Text(txn.last4.map { "••\($0)" } ?? txn.instrument.label)
                    if txn.category == Category.uncategorized { Text("· to sort").foregroundColor(Theme.gold) }
                }
                .font(.caption2).foregroundColor(Theme.dim).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text((txn.direction == .credit ? "+" : "") + Money.format(txn.amount))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundColor(txn.direction == .credit ? Theme.profit : Theme.text)
                Text(c.name).font(.caption2).foregroundColor(Theme.faint).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .opacity(txn.excluded ? 0.45 : 1)
    }
}

struct AccountsStrip: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let accounts = store.state.balances.values.filter { $0.kind == .savings || $0.kind == .broker }.sorted { $0.balance > $1.balance }
        if !accounts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "Balances", trailing: "from bank and exchange SMS")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(accounts) { a in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 5) {
                                    Image(systemName: a.kind == .broker ? "chart.bar.fill" : "building.columns.fill").font(.caption).foregroundColor(Theme.gold)
                                    Text(a.title).font(.caption.weight(.semibold)).lineLimit(1)
                                }
                                Text(Money.format(a.balance, paise: false)).font(.system(.headline, design: .rounded)).monospacedDigit()
                                Text("as of " + Cal.dayMonthFormatter.string(from: a.asOf)).font(.caption2).foregroundColor(Theme.faint)
                            }
                            .padding(12)
                            .frame(minWidth: 150, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.cardRaised))
                        }
                    }
                }
            }
            .card()
        }
    }
}
