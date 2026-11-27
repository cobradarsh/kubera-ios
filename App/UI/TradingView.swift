import SwiftUI
import UIKit
import Charts
import PhotosUI
import Photos

enum TradeChart: String, CaseIterable {
    case daily, equity, calendar, weekday, months, brokers, underlying
    var label: String {
        switch self {
        case .daily: return "Daily P&L"
        case .equity: return "Equity curve"
        case .calendar: return "Calendar"
        case .weekday: return "By weekday"
        case .months: return "12 months"
        case .brokers: return "By broker"
        case .underlying: return "By index"
        }
    }
    var symbol: String {
        switch self {
        case .daily: return "chart.bar.xaxis"
        case .equity: return "chart.line.uptrend.xyaxis"
        case .calendar: return "calendar"
        case .weekday: return "calendar.day.timeline.left"
        case .months: return "calendar.badge.clock"
        case .brokers: return "building.2.fill"
        case .underlying: return "chart.pie.fill"
        }
    }
}

struct TradingView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @State private var month = Cal.startOfMonth(Date())
    @AppStorage(Pref.tradeChartKind) private var chartRaw = TradeChart.daily.rawValue
    @AppStorage(Pref.autoScanScreenshots) private var autoScan = true
    @State private var findings: [ScreenshotFinding] = []
    @State private var scanning = false
    @State private var picked: [PhotosPickerItem] = []
    /// One sheet for the whole screen (several .sheet modifiers on one view do not all present on iOS 16).
    @State private var sheet: TradeSheet?
    @State private var importing = false
    @State private var importProblem: String?

    enum TradeSheet: Identifiable {
        case edit(TradeDay)
        case review
        var id: String {
            switch self {
            case .edit(let d): return "edit:" + d.id
            case .review: return "review"
            }
        }
    }

    private func edit(_ d: TradeDay) { sheet = .edit(d) }

    /// The saved record for that day at the usual broker, or a new one to fill in.
    private func draft(for day: Date) -> TradeDay {
        let broker = store.usualBroker
        return store.state.trades[TradeDay.key(day, broker)] ?? TradeDay(id: TradeDay.key(day, broker), date: day, broker: broker, pnl: 0)
    }

    private var chart: Binding<TradeChart> {
        Binding(get: { TradeChart(rawValue: chartRaw) ?? .daily }, set: { chartRaw = $0.rawValue })
    }

    var body: some View {
        let days = store.ledger.trades(inMonth: month)
        let stats = TradeStats(days: days)
        let missing = store.ledger.missingTradeDays(inMonth: month)
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    MantraHeader()
                    MonthSwitcher(month: $month)
                    PnLSummary(stats: stats)
                    if !findings.isEmpty {
                        Button { sheet = .review } label: {
                            HStack {
                                Image(systemName: "photo.stack.fill").foregroundColor(.black)
                                Text("\(findings.count) broker screenshot\(findings.count == 1 ? "" : "s") found").fontWeight(.semibold).foregroundColor(.black)
                                Spacer()
                                Text("Review").font(.footnote.weight(.semibold)).foregroundColor(.black.opacity(0.7))
                            }
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.goldGradient))
                        }
                        .buttonStyle(.plain)
                    }
                    addRow
                    VStack(alignment: .leading, spacing: 12) {
                        ChipPicker(items: TradeChart.allCases, selection: chart, label: { $0.label }, symbol: { $0.symbol })
                        TradeChartView(kind: chart.wrappedValue, month: month, stats: stats)
                            .frame(minHeight: 230)
                    }
                    .card()
                    if !missing.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionTitle(title: "Traded, no P&L yet", trailing: "from BSE/NSE turnover SMS")
                            ForEach(missing, id: \.self) { d in
                                Button { edit(draft(for: d)) } label: {
                                    HStack {
                                        Text(Cal.dayTitleFormatter.string(from: d))
                                        Spacer()
                                        Text(turnover(on: d)).font(.caption).foregroundColor(Theme.dim)
                                        Image(systemName: "plus.circle.fill").foregroundColor(Theme.gold)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .card()
                    }
                    dayList(days)
                    HoldingsCard()
                    NavigationLink { HolidaysView() } label: {
                        HStack {
                            Image(systemName: "calendar.badge.exclamationmark").foregroundColor(Theme.gold)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Market holidays").font(.subheadline.weight(.semibold))
                                Text(nextHolidayText).font(.caption).foregroundColor(Theme.dim)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundColor(Theme.faint)
                        }
                        .card()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .refreshable { await scan(force: true) }
            .kuberaScreen()
            .navigationTitle("Investments & Trading")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Text(Holidays.marketStatus(extra: store.state.userHolidays)).font(.caption2).foregroundColor(Theme.dim)
                }
            }
            .sheet(item: $sheet) { s in
                switch s {
                case .edit(let d): TradeEditView(day: d)
                case .review: ScreenshotReviewView(findings: $findings)
                }
            }
            .overlay {
                if importing {
                    VStack(spacing: 10) {
                        ProgressView().tint(Theme.gold)
                        Text("Reading the screenshot…").font(.footnote).foregroundColor(Theme.dim)
                    }
                    .padding(22)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Theme.cardRaised))
                }
            }
            .alert("Could not read that picture", isPresented: Binding(get: { importProblem != nil }, set: { if !$0 { importProblem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(importProblem ?? "") }
            .onChange(of: picked) { items in Task { await importPicked(items) } }
            .onChange(of: router.showImport) { show in
                if show { router.showImport = false; sheet = .review }
            }
            .onReceive(router.$diagFindings) { list in
                guard !list.isEmpty else { return }
                findings += list
                router.diagFindings = []
                sheet = .review
            }
            .task { if autoScan { await scan(force: false) } }
        }
    }

    private var addRow: some View {
        HStack(spacing: 10) {
            // photoLibrary gives each picked item its library id, so the screenshot's own date can be looked up.
            PhotosPicker(selection: $picked, maxSelectionCount: 10, matching: .screenshots, photoLibrary: .shared()) {
                Label("Screenshot", systemImage: "photo.badge.plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.gold)
            .foregroundColor(.black)
            Button {
                Task { await scan(force: true) }
            } label: {
                Label(scanning ? "Scanning…" : "Find new", systemImage: "sparkle.magnifyingglass").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(Theme.gold)
            .disabled(scanning)
            Button {
                let d = Holidays.isTradingDay(Date(), extra: store.state.userHolidays) ? Cal.startOfDay(Date()) : Holidays.previousTradingDay(before: Date())
                edit(draft(for: d))
            } label: { Image(systemName: "square.and.pencil").padding(.horizontal, 6) }
            .buttonStyle(.bordered)
            .tint(Theme.gold)
        }
        .font(.footnote.weight(.semibold))
    }

    private func dayList(_ days: [TradeDay]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "Days", trailing: "\(days.count) recorded")
            if days.isEmpty {
                EmptyNote(symbol: "camera.viewfinder", title: "No P&L this month yet",
                          detail: "Take a screenshot of your positions after the market closes. Kubera finds it and reads the P&L.")
            }
            ForEach(days.sorted { $0.date > $1.date }) { d in
                Button { edit(d) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Cal.dayTitleFormatter.string(from: d.date)).font(.subheadline.weight(.medium))
                            Text(d.broker + (d.positions.isEmpty ? "" : " · \(d.positions.count) positions") + (d.source == .screenshot ? " · screenshot" : ""))
                                .font(.caption2).foregroundColor(Theme.dim)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            AmountText(value: d.net, signed: true, paise: false)
                            if let c = d.charges, c > 0 { Text("charges \(Money.format(c, paise: false))").font(.caption2).foregroundColor(Theme.faint) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                if d.id != days.sorted(by: { $0.date > $1.date }).last?.id { Divider().background(Theme.stroke) }
            }
        }
        .card()
    }

    private var nextHolidayText: String {
        if let h = Holidays.next(Holidays.nse2026 + store.state.userHolidays.filter { $0.kind != .india }) {
            return "Next NSE holiday: \(h.name), \(Cal.dayTitleFormatter.string(from: h.date))"
        }
        return "NSE's list for next year is published in December"
    }

    private func turnover(on d: Date) -> String {
        let v = store.state.turnovers.values.filter { Cal.sameDay($0.date, d) }.reduce(0) { $0 + $1.value }
        return "turnover \(Money.compact(v))"
    }

    private func scan(force: Bool) async {
        guard !scanning else { return }
        // The Invest tab appears often; looking again within two minutes finds nothing new.
        if !force, let last = TradingView.lastAutoScan, Date().timeIntervalSince(last) < 120 { return }
        if !ScreenshotScanner.authorized() {
            guard force else { return }
            guard await ScreenshotScanner.requestAccess() else { return }
        }
        scanning = true
        defer { scanning = false }
        TradingView.lastAutoScan = Date()
        let since = store.state.lastScreenshotScan.map { $0.addingTimeInterval(-3 * 86400) } ?? Cal.addDays(-3, to: Date())
        let skip = Set(store.state.seenAssets)
        let result = await ScreenshotScanner.scan(since: since, skip: skip, holidays: store.state.userHolidays)
        let known = Set(findings.map { $0.assetID }).union(store.state.seenAssets)
        findings += result.findings.filter { !known.contains($0.assetID) }
        Diag.log("screenshot scan: \(result.findings.count) broker screenshots, \(result.examined.count) others since \(since)")
        // Screenshots that are not broker screens are not read again; broker ones are remembered once reviewed.
        store.markSeenAssets(result.examined)
    }

    static var lastAutoScan: Date?

    /// Pictures chosen with the Screenshot button: always ends in the review sheet (to type the P&L by hand if
    /// nothing could be read) or in a message saying why not.
    private func importPicked(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        importing = true
        defer { importing = false }
        // The photo library knows when each screenshot was taken; ask once for access if not asked yet.
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined { _ = await ScreenshotScanner.requestAccess() }
        var added = 0
        var failures: [String] = []
        for item in items {
            let id = item.itemIdentifier ?? UUID().uuidString
            var img: UIImage?
            var created: Date?
            if let ident = item.itemIdentifier, ScreenshotScanner.authorized(),
               let asset = PHAsset.fetchAssets(withLocalIdentifiers: [ident], options: nil).firstObject {
                created = asset.creationDate
                img = await ScreenshotScanner.image(for: asset)
            }
            if img == nil || created == nil {
                do {
                    if let data = try await item.loadTransferable(type: Data.self) {
                        if img == nil { img = UIImage(data: data) }
                        if created == nil { created = ScreenshotScanner.takenDate(in: data) }
                    }
                } catch {
                    Diag.log("import: loadTransferable failed \(error.localizedDescription)")
                    failures.append(error.localizedDescription)
                }
            }
            guard let image = img else {
                Diag.log("import: no image for \(id)")
                continue
            }
            let reading = await ScreenshotScanner.read(image)
            let when = created ?? Date()
            let day = Holidays.tradingDay(forScreenshotAt: when, extra: store.state.userHolidays, commodity: reading.commodity)
            Diag.log("import: \(Int(image.size.width))x\(Int(image.size.height)) taken \(created.map { "\($0)" } ?? "unknown") broker=\(reading.broker ?? "-") kind=\(reading.kind.rawValue) total=\(reading.total.map { String($0) } ?? "-") conf=\(reading.confidence) notes=\(reading.notes)")
            if !findings.contains(where: { $0.assetID == id }) {
                findings.append(ScreenshotFinding(assetID: id, created: when, image: image, reading: reading, tradingDay: day,
                                                  dateKnown: created != nil))
                added += 1
            }
        }
        picked = []
        if added > 0 || !findings.isEmpty {
            sheet = .review
        } else {
            importProblem = failures.first.map { "iOS did not hand the picture over (\($0)). Try again, or tap ✎ to type the day's P&L." }
                ?? "iOS did not hand the picture over. Try again, or tap ✎ to type the day's P&L."
        }
    }
}

struct PnLSummary: View {
    var stats: TradeStats
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Net P&L this month").font(.caption).foregroundColor(Theme.dim)
                    Text(Money.signed(stats.net))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(Theme.pnl(stats.net))
                        .monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.0f%% win days", stats.winRate * 100)).font(.footnote.weight(.semibold)).foregroundColor(Theme.gold)
                    Text("\(stats.winDays) up · \(stats.lossDays) down").font(.caption2).foregroundColor(Theme.faint)
                }
            }
            HStack(spacing: 8) {
                StatTile(title: "Best day", value: stats.best.map { Money.compact($0.net) } ?? "–", color: Theme.profit,
                         sub: stats.best.map { Cal.dayMonthFormatter.string(from: $0.date) })
                StatTile(title: "Worst day", value: stats.worst.map { Money.compact($0.net) } ?? "–", color: Theme.loss,
                         sub: stats.worst.map { Cal.dayMonthFormatter.string(from: $0.date) })
                StatTile(title: "Profit factor", value: stats.profitFactor.map { String(format: "%.2f", $0) } ?? "–")
                StatTile(title: "Max drawdown", value: Money.compact(stats.maxDrawdown), color: stats.maxDrawdown < 0 ? Theme.loss : Theme.text)
            }
            HStack(spacing: 8) {
                StatTile(title: "Avg win", value: Money.compact(stats.avgWin), color: Theme.profit)
                StatTile(title: "Avg loss", value: Money.compact(stats.avgLoss), color: Theme.loss)
                StatTile(title: "Charges", value: Money.compact(stats.charges))
                StatTile(title: "Streaks", value: "\(stats.streaks.win)W / \(stats.streaks.loss)L")
            }
        }
        .card(padding: 16)
    }
}

struct TradeChartView: View {
    @EnvironmentObject var store: Store
    var kind: TradeChart
    var month: Date
    var stats: TradeStats

    struct Bar: Identifiable { var id: String; var label: String; var date: Date; var value: Double }

    var body: some View {
        switch kind {
        case .daily: daily
        case .equity: equity
        case .calendar: TradeCalendar(month: month, stats: stats)
        case .weekday: weekday
        case .months: months
        case .brokers: named(stats.byBroker().map { ($0.broker, $0.net) }, empty: "No days recorded yet.")
        case .underlying: named(stats.byUnderlying().map { ($0.name, $0.pnl) }, empty: "Position rows appear when a screenshot lists them.")
        }
    }

    private var empty: some View {
        Text("No P&L recorded for this month.").font(.footnote).foregroundColor(Theme.dim).frame(maxWidth: .infinity, minHeight: 200)
    }

    @ViewBuilder private var daily: some View {
        let rows = stats.byDate
        if rows.isEmpty { empty } else {
            Chart {
                ForEach(rows, id: \.date) { r in
                    BarMark(x: .value("Day", r.date, unit: .day), y: .value("P&L", r.net))
                        .foregroundStyle(r.net >= 0 ? Theme.profit : Theme.loss)
                        .cornerRadius(3)
                }
                RuleMark(y: .value("Zero", 0)).foregroundStyle(Theme.stroke)
            }
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 5)) { _ in AxisValueLabel(format: .dateTime.day(), centered: true) } }
            .chartYAxis { AxisMarks { v in AxisGridLine().foregroundStyle(Theme.stroke); AxisValueLabel { Text(Money.compact(v.as(Double.self) ?? 0)) } } }
            .frame(height: 220)
        }
    }

    @ViewBuilder private var equity: some View {
        let curve = stats.equityCurve
        if curve.isEmpty { empty } else {
            let last = curve.last?.value ?? 0
            Chart {
                ForEach(curve, id: \.date) { p in
                    AreaMark(x: .value("Day", p.date, unit: .day), y: .value("Cumulative", p.value))
                        .foregroundStyle(LinearGradient(colors: [Theme.pnl(last).opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Day", p.date, unit: .day), y: .value("Cumulative", p.value))
                        .foregroundStyle(Theme.pnl(last))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                    PointMark(x: .value("Day", p.date, unit: .day), y: .value("Cumulative", p.value))
                        .foregroundStyle(Theme.pnl(last)).symbolSize(18)
                }
                RuleMark(y: .value("Zero", 0)).foregroundStyle(Theme.stroke)
            }
            .chartYAxis { AxisMarks { v in AxisGridLine().foregroundStyle(Theme.stroke); AxisValueLabel { Text(Money.compact(v.as(Double.self) ?? 0)) } } }
            .frame(height: 220)
        }
    }

    @ViewBuilder private var weekday: some View {
        let rows = stats.byWeekday()
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri"]
        if stats.tradingDays == 0 { empty } else {
            Chart {
                ForEach(rows, id: \.weekday) { r in
                    BarMark(x: .value("Weekday", names[r.weekday - 1]), y: .value("P&L", r.net))
                        .foregroundStyle(r.net >= 0 ? Theme.profit : Theme.loss)
                        .cornerRadius(4)
                        .annotation(position: r.net >= 0 ? .top : .bottom) { Text(Money.compact(r.net)).font(.caption2).foregroundColor(Theme.dim) }
                }
            }
            .chartXScale(domain: names)
            .chartYAxis { AxisMarks { v in AxisGridLine().foregroundStyle(Theme.stroke); AxisValueLabel { Text(Money.compact(v.as(Double.self) ?? 0)) } } }
            .frame(height: 220)
        }
    }

    @ViewBuilder private var months: some View {
        let all = TradeStats(days: Array(store.state.trades.values))
        let end = Cal.startOfMonth(month)
        let bars: [Bar] = (0..<12).map { i in
            let m = Cal.addMonths(-(11 - i), to: end)
            let v = all.days.filter { Cal.sameMonth($0.date, m) }.reduce(0) { $0 + $1.net }
            return Bar(id: Cal.dayKey(m), label: Cal.shortMonthFormatter.string(from: m), date: m, value: v)
        }
        Chart {
            ForEach(bars) { b in
                BarMark(x: .value("Month", b.date, unit: .month), y: .value("P&L", b.value))
                    .foregroundStyle(b.value >= 0 ? Theme.profit : Theme.loss)
                    .cornerRadius(3)
            }
            RuleMark(y: .value("Zero", 0)).foregroundStyle(Theme.stroke)
        }
        .chartXAxis { AxisMarks(values: .stride(by: .month, count: 2)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated), centered: true) } }
        .chartYAxis { AxisMarks { v in AxisGridLine().foregroundStyle(Theme.stroke); AxisValueLabel { Text(Money.compact(v.as(Double.self) ?? 0)) } } }
        .frame(height: 220)
    }

    @ViewBuilder private func named(_ rows: [(String, Double)], empty text: String) -> some View {
        if rows.isEmpty {
            Text(text).font(.footnote).foregroundColor(Theme.dim).frame(maxWidth: .infinity, minHeight: 200)
        } else {
            let bars = rows.prefix(10).map { Bar(id: $0.0, label: $0.0, date: Date(), value: $0.1) }
            Chart(bars) { b in
                BarMark(x: .value("P&L", b.value), y: .value("Name", b.label))
                    .foregroundStyle(b.value >= 0 ? Theme.profit : Theme.loss)
                    .cornerRadius(4)
                    .annotation(position: b.value >= 0 ? .trailing : .leading) { Text(Money.compact(b.value)).font(.caption2).foregroundColor(Theme.dim) }
            }
            .chartXAxis(.hidden)
            .frame(height: CGFloat(max(150, bars.count * 32)))
        }
    }
}

/// Trading-journal style month: green and red days.
struct TradeCalendar: View {
    @EnvironmentObject var store: Store
    var month: Date
    var stats: TradeStats
    var body: some View {
        let byKey = Dictionary(stats.byDate.map { (Cal.dayKey($0.date), $0.net) }, uniquingKeysWith: +)
        let maxAbs = byKey.values.map { abs($0) }.max() ?? 0
        let start = Cal.startOfMonth(month)
        let lead = Cal.weekdayMon(start) - 1
        let count = Cal.daysInMonth(month)
        VStack(spacing: 8) {
            HStack { ForEach(Array(["M", "T", "W", "T", "F", "S", "S"].enumerated()), id: \.offset) { _, d in
                Text(d).font(.caption2).foregroundColor(Theme.faint).frame(maxWidth: .infinity)
            } }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 5) {
                ForEach(0..<lead, id: \.self) { _ in Color.clear.frame(height: 42) }
                ForEach(0..<count, id: \.self) { i in
                    let d = Cal.addDays(i, to: start)
                    let v = byKey[Cal.dayKey(d)]
                    let open = Holidays.isTradingDay(d, extra: store.state.userHolidays)
                    let share = (v.map { abs($0) } ?? 0) / max(1, maxAbs)
                    VStack(spacing: 1) {
                        Text("\(i + 1)").font(.caption2.weight(.semibold))
                        if let v { Text(Money.compact(v)).font(.system(size: 8)).lineLimit(1).minimumScaleFactor(0.6) }
                        else if !open { Text(Cal.weekdayMon(d) >= 6 ? "" : "holiday").font(.system(size: 7)).foregroundColor(Theme.faint) }
                    }
                    .foregroundColor(v == nil ? (open ? Theme.text : Theme.faint) : .white)
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .background(RoundedRectangle(cornerRadius: 7).fill(cellColor(v, share: share, open: open)))
                }
            }
        }
    }

    private func cellColor(_ v: Double?, share: Double, open: Bool) -> Color {
        guard let v else { return open ? Theme.cardRaised : Color(white: 0.04) }
        let base = v >= 0 ? Theme.profit : Theme.loss
        return base.opacity(0.25 + 0.65 * share)
    }
}

/// Holdings value read from holdings screenshots, plus manual investments; feeds Net Worth.
struct HoldingsCard: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let investKinds: Set<AssetKind> = [.stocks, .mutualFunds, .fixedDeposit, .gold, .nps, .providentFund, .crypto, .broker]
        let items = store.state.manual.filter { investKinds.contains($0.kind) }
        let total = items.reduce(0) { $0 + $1.value }
        let brokers = store.state.balances.values.filter { $0.kind == .broker }
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Investments", trailing: Money.compact(total + brokers.reduce(0) { $0 + $1.balance }))
            ForEach(brokers) { b in
                HStack {
                    Image(systemName: "chart.bar.fill").foregroundColor(Theme.gold).frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(b.institution + " (cash + securities)").font(.subheadline)
                        Text("reported by NSE on " + Cal.dayMonthFormatter.string(from: b.asOf)).font(.caption2).foregroundColor(Theme.faint)
                    }
                    Spacer()
                    Text(Money.format(b.balance, paise: false)).font(.subheadline.weight(.semibold)).monospacedDigit()
                }
            }
            ForEach(items) { m in
                HStack {
                    Image(systemName: m.kind.symbol).foregroundColor(Theme.gold).frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.name).font(.subheadline)
                        Text(m.kind.label + " · " + Cal.dayMonthFormatter.string(from: m.updated)).font(.caption2).foregroundColor(Theme.faint)
                    }
                    Spacer()
                    Text(Money.format(m.value, paise: false)).font(.subheadline.weight(.semibold)).monospacedDigit()
                }
            }
            if items.isEmpty && brokers.isEmpty {
                Text("Add holdings in Net Worth, or import a holdings screenshot.").font(.footnote).foregroundColor(Theme.dim)
            }
        }
        .card()
    }
}
