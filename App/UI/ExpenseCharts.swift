import SwiftUI
import Charts

struct ExpenseChartView: View {
    @EnvironmentObject var store: Store
    var kind: ExpenseChart
    var month: Date
    var list: [Txn]

    var body: some View {
        switch kind {
        case .daily: DailyBars(month: month)
        case .cumulative: CumulativeLines(month: month)
        case .donut: CategoryDonut(list: list)
        case .categories: CategoryBars(list: list)
        case .weekly: WeeklyStack(month: month)
        case .trend: TrendStack(month: month)
        case .calendar: SpendCalendar(month: month)
        case .methods: MethodDonut(list: list)
        case .when: WhenHeat(list: list)
        case .merchants: MerchantBars(list: list)
        }
    }
}

private struct NoData: View {
    var body: some View {
        Text("No spending to show for this month yet.")
            .font(.footnote).foregroundColor(Theme.dim)
            .frame(maxWidth: .infinity, minHeight: 200)
    }
}

/// Spending per day with the month's daily average.
struct DailyBars: View {
    @EnvironmentObject var store: Store
    var month: Date
    /// The tapped day; its amount is read from the current totals, so an edit made since shows at once.
    @State private var pickedDay: Date?

    var body: some View {
        let days = store.spend.byDay(month: month)
        let picked = days.first { $0.day == pickedDay }
        let total = days.reduce(0) { $0 + $1.amount }
        let avg = days.isEmpty ? 0 : total / Double(days.count)
        VStack(alignment: .leading, spacing: 6) {
            Text(picked.map { "\(Cal.dayTitleFormatter.string(from: $0.day)): \(Money.format($0.amount, paise: false))" }
                 ?? "Average \(Money.format(avg, paise: false)) a day")
                .font(.caption).foregroundColor(Theme.dim)
            if total <= 0 { NoData() } else {
                Chart {
                    ForEach(days) { d in
                        BarMark(x: .value("Day", d.day, unit: .day), y: .value("Spent", max(0, d.amount)))
                            .foregroundStyle(picked?.day == d.day ? Theme.goldLight : Theme.gold)
                            .cornerRadius(3)
                    }
                    RuleMark(y: .value("Average", avg))
                        .foregroundStyle(Theme.dim)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                        AxisGridLine().foregroundStyle(Theme.stroke)
                        AxisValueLabel(format: .dateTime.day(), centered: true)
                    }
                }
                .chartYAxis { AxisMarks { v in AxisGridLine().foregroundStyle(Theme.stroke); AxisValueLabel { Text(Money.compact(v.as(Double.self) ?? 0)) } } }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        // A tap (not a drag) picks a day, so a swipe that starts on the chart still scrolls the screen.
                        // Tapping the picked day again clears it.
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { tap in
                                let x = tap.location.x - geo[proxy.plotAreaFrame].origin.x
                                guard let date: Date = proxy.value(atX: x) else { return }
                                let day = days.min { abs($0.day.timeIntervalSince(date)) < abs($1.day.timeIntervalSince(date)) }?.day
                                pickedDay = day == pickedDay ? nil : day
                            })
                    }
                }
                .frame(height: 220)
            }
        }
        .onChange(of: month) { _ in pickedDay = nil }
    }
}

/// This month's running total against last month's, with the budget line.
struct CumulativeLines: View {
    @EnvironmentObject var store: Store
    var month: Date

    struct Point: Identifiable { var id: String; var day: Int; var amount: Double; var series: String }

    var body: some View {
        let s = store.spend
        let now = Date()
        let cur = s.cumulative(month: month, now: now)
        let prevMonth = Cal.addMonths(-1, to: month)
        let prev = s.cumulative(month: prevMonth, now: now)
        let curName = Cal.shortMonthFormatter.string(from: month)
        let prevName = Cal.shortMonthFormatter.string(from: prevMonth)
        let points = cur.map { Point(id: "c\(Cal.day($0.day))", day: Cal.day($0.day), amount: $0.amount, series: curName) }
            + prev.map { Point(id: "p\(Cal.day($0.day))", day: Cal.day($0.day), amount: $0.amount, series: prevName) }
        let budget = store.state.budgets["total"]
        VStack(alignment: .leading, spacing: 6) {
            Text("Day by day, from the 1st").font(.caption).foregroundColor(Theme.dim)
            if points.isEmpty { NoData() } else {
                Chart {
                    ForEach(points) { p in
                        LineMark(x: .value("Day", p.day), y: .value("Total", p.amount))
                            .foregroundStyle(by: .value("Month", p.series))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: p.series == curName ? 3 : 1.5))
                    }
                    if let b = budget, b > 0 {
                        RuleMark(y: .value("Budget", b)).foregroundStyle(Theme.loss.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                            .annotation(position: .top, alignment: .leading) { Text("Budget").font(.caption2).foregroundColor(Theme.loss) }
                    }
                }
                .chartForegroundStyleScale(domain: [curName, prevName], range: [Theme.gold, Theme.dim])
                .chartXScale(domain: 1...31)
                .chartYAxis { AxisMarks { v in AxisGridLine().foregroundStyle(Theme.stroke); AxisValueLabel { Text(Money.compact(v.as(Double.self) ?? 0)) } } }
                .frame(height: 220)
            }
        }
    }
}

struct CategoryDonut: View {
    @EnvironmentObject var store: Store
    var list: [Txn]
    var body: some View {
        let totals = store.spend.byCategory(list)
        let sum = totals.reduce(0) { $0 + $1.amount }
        let slices = totals.map { DonutSlice(id: $0.category, value: $0.amount, color: Color(hex: store.category($0.category).colorHex), label: store.category($0.category).name) }
        if totals.isEmpty { NoData() } else {
            VStack(spacing: 14) {
                DonutChart(slices: slices) {
                    VStack(spacing: 2) {
                        Text(Money.compact(sum)).font(.system(.title2, design: .rounded).weight(.bold)).foregroundStyle(Theme.goldGradient)
                        Text("\(totals.count) categories").font(.caption2).foregroundColor(Theme.dim)
                    }
                }
                .frame(height: 200)
                VStack(spacing: 6) {
                    ForEach(slices.prefix(8)) { s in
                        LegendRow(color: s.color, label: s.label, value: Money.compact(s.value), share: sum > 0 ? s.value / sum : nil)
                    }
                }
            }
        }
    }
}

struct CategoryBars: View {
    @EnvironmentObject var store: Store
    var list: [Txn]
    var body: some View {
        let totals = Array(store.spend.byCategory(list).prefix(10))
        let names = totals.map { store.category($0.category).name }
        let colors = totals.map { Color(hex: store.category($0.category).colorHex) }
        if totals.isEmpty { NoData() } else {
            Chart(totals) { t in
                BarMark(x: .value("Spent", t.amount), y: .value("Category", store.category(t.category).name))
                    .foregroundStyle(by: .value("Category", store.category(t.category).name))
                    .cornerRadius(4)
                    .annotation(position: .trailing) { Text(Money.compact(t.amount)).font(.caption2).foregroundColor(Theme.dim) }
            }
            .chartForegroundStyleScale(domain: names, range: colors)
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .frame(height: CGFloat(max(160, totals.count * 30)))
        }
    }
}

struct WeeklyStack: View {
    @EnvironmentObject var store: Store
    var month: Date
    struct Cell: Identifiable { var id: String; var week: String; var category: String; var amount: Double }
    var body: some View {
        let rows = store.spend.weeklyByCategory(month: month)
        let cells = rows.map { Cell(id: "\($0.week)\($0.category)", week: "Week \($0.week)", category: store.category($0.category).name, amount: $0.amount) }
        let names = Array(Set(cells.map { $0.category })).sorted()
        let colors = names.map { n in Color(hex: store.categories.first { $0.name == n }?.colorHex ?? "#9E9E9E") }
        VStack(alignment: .leading, spacing: 6) {
            Text("Weeks run 1–7, 8–14, 15–21, 22–28, 29+").font(.caption).foregroundColor(Theme.dim)
            if cells.isEmpty { NoData() } else {
                Chart(cells) { c in
                    BarMark(x: .value("Week", c.week), y: .value("Spent", c.amount))
                        .foregroundStyle(by: .value("Category", c.category))
                }
                .chartForegroundStyleScale(domain: names, range: colors)
                .chartLegend(position: .bottom, spacing: 8)
                .chartYAxis { AxisMarks { v in AxisGridLine().foregroundStyle(Theme.stroke); AxisValueLabel { Text(Money.compact(v.as(Double.self) ?? 0)) } } }
                .frame(height: 240)
            }
        }
    }
}

struct TrendStack: View {
    @EnvironmentObject var store: Store
    var month: Date
    var body: some View {
        let rows = store.spend.monthlyByCategory(endingAt: month, months: 6)
        let names = Array(Set(rows.map { store.category($0.category).name })).sorted()
        let colors = names.map { n in Color(hex: store.categories.first { $0.name == n }?.colorHex ?? "#9E9E9E") }
        VStack(alignment: .leading, spacing: 6) {
            Text("Last six months by category").font(.caption).foregroundColor(Theme.dim)
            if rows.isEmpty { NoData() } else {
                Chart(rows) { r in
                    BarMark(x: .value("Month", r.month, unit: .month), y: .value("Spent", r.amount))
                        .foregroundStyle(by: .value("Category", store.category(r.category).name))
                }
                .chartForegroundStyleScale(domain: names, range: colors)
                .chartLegend(position: .bottom, spacing: 8)
                .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated), centered: true) } }
                .chartYAxis { AxisMarks { v in AxisGridLine().foregroundStyle(Theme.stroke); AxisValueLabel { Text(Money.compact(v.as(Double.self) ?? 0)) } } }
                .frame(height: 240)
            }
        }
    }
}

/// A month calendar, each day shaded by what was spent.
struct SpendCalendar: View {
    @EnvironmentObject var store: Store
    var month: Date
    var body: some View {
        let days = store.spend.byDay(month: month, now: Date.distantFuture)
        let maxV = days.map { $0.amount }.max() ?? 0
        let lead = Cal.weekdayMon(Cal.startOfMonth(month)) - 1
        let cols = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)
        VStack(spacing: 8) {
            HStack { ForEach(["M", "T", "W", "T", "F", "S", "S"].indices, id: \.self) { i in
                Text(["M", "T", "W", "T", "F", "S", "S"][i]).font(.caption2).foregroundColor(Theme.faint).frame(maxWidth: .infinity)
            } }
            LazyVGrid(columns: cols, spacing: 5) {
                ForEach(0..<lead, id: \.self) { _ in Color.clear.frame(height: 40) }
                ForEach(days) { d in
                    let share = maxV > 0 ? d.amount / maxV : 0
                    VStack(spacing: 1) {
                        Text("\(Cal.day(d.day))").font(.caption2.weight(.semibold))
                        Text(d.amount > 0 ? Money.compact(d.amount) : "").font(.system(size: 8)).lineLimit(1).minimumScaleFactor(0.6)
                    }
                    .foregroundColor(share > 0.55 ? .black : Theme.text)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(RoundedRectangle(cornerRadius: 7).fill(d.amount > 0 ? Theme.gold.opacity(0.18 + 0.82 * share) : Theme.cardRaised))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Cal.sameDay(d.day, Date()) ? Theme.goldLight : .clear, lineWidth: 1.5))
                }
            }
        }
    }
}

struct MethodDonut: View {
    @EnvironmentObject var store: Store
    var list: [Txn]
    private let palette: [Color] = [Color(hex: "#D4AF37"), Color(hex: "#29B6F6"), Color(hex: "#AB47BC"), Color(hex: "#66BB6A"), Color(hex: "#FF7043"), Color(hex: "#BDBDBD"), Color(hex: "#F48FB1"), Color(hex: "#8D6E63")]
    var body: some View {
        let rows = store.spend.byInstrument(list)
        let sum = rows.reduce(0) { $0 + $1.1 }
        let slices = rows.enumerated().map { i, r in DonutSlice(id: r.0.rawValue, value: r.1, color: palette[i % palette.count], label: r.0.label) }
        if rows.isEmpty { NoData() } else {
            VStack(spacing: 14) {
                DonutChart(slices: slices) {
                    VStack(spacing: 2) {
                        Image(systemName: "creditcard.fill").foregroundColor(Theme.gold)
                        Text("How you paid").font(.caption2).foregroundColor(Theme.dim)
                    }
                }
                .frame(height: 190)
                VStack(spacing: 6) {
                    ForEach(slices) { s in LegendRow(color: s.color, label: s.label, value: Money.compact(s.value), share: sum > 0 ? s.value / sum : nil) }
                }
            }
        }
    }
}

/// Day of week against time of day.
struct WhenHeat: View {
    @EnvironmentObject var store: Store
    var list: [Txn]
    private let slots = ["12a", "3a", "6a", "9a", "12p", "3p", "6p", "9p"]
    private let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    var body: some View {
        let cells = store.spend.heat(list)
        let maxV = cells.map { $0.amount }.max() ?? 0
        VStack(alignment: .leading, spacing: 6) {
            Text("When you spend (3-hour blocks)").font(.caption).foregroundColor(Theme.dim)
            if maxV <= 0 { NoData() } else {
                Chart(cells) { c in
                    RectangleMark(x: .value("Time", slots[c.slot]), y: .value("Day", days[c.weekday - 1]))
                        .foregroundStyle(Theme.gold.opacity(c.amount <= 0 ? 0.05 : 0.15 + 0.85 * c.amount / maxV))
                        .cornerRadius(4)
                }
                .chartXScale(domain: slots)
                .chartYScale(domain: days)
                .frame(height: 230)
            }
        }
    }
}

struct MerchantBars: View {
    @EnvironmentObject var store: Store
    var list: [Txn]
    var body: some View {
        let rows = store.spend.topMerchants(list, limit: 10)
        if rows.isEmpty { NoData() } else {
            Chart(rows) { r in
                BarMark(x: .value("Spent", r.amount), y: .value("Payee", r.name))
                    .foregroundStyle(Theme.goldGradient)
                    .cornerRadius(4)
                    .annotation(position: .trailing) { Text("\(Money.compact(r.amount)) · \(r.count)×").font(.caption2).foregroundColor(Theme.dim) }
            }
            .chartXAxis(.hidden)
            .frame(height: CGFloat(max(160, rows.count * 30)))
        }
    }
}
