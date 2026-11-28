import SwiftUI
import UIKit

/// True black with gold, for the OLED screen.
enum Theme {
    static let bg = Color.black
    static let card = Color(white: 0.075)
    static let cardRaised = Color(white: 0.11)
    static let stroke = Color(white: 0.17)
    static let gold = Color(hex: "#D4AF37")
    static let goldLight = Color(hex: "#F5D77A")
    static let goldDeep = Color(hex: "#9C7A1E")
    static let text = Color.white
    static let dim = Color(white: 0.62)
    static let faint = Color(white: 0.4)
    static let profit = Color(hex: "#30D158")
    static let loss = Color(hex: "#FF453A")
    static let goldGradient = LinearGradient(colors: [goldLight, gold, goldDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let accentUI = UIColor(red: 0.83, green: 0.69, blue: 0.22, alpha: 1)

    static func pnl(_ v: Double) -> Color { v > 0.004 ? profit : (v < -0.004 ? loss : dim) }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xFF) / 255, g = Double((v >> 8) & 0xFF) / 255, b = Double(v & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

struct CardModifier: ViewModifier {
    var padding: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }
}

extension View {
    func card(padding: CGFloat = 14) -> some View { modifier(CardModifier(padding: padding)) }

    /// Screen background + list styling used everywhere.
    func kuberaScreen() -> some View {
        self.scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
    }
}

struct SectionTitle: View {
    var title: String
    var trailing: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(.headline, design: .rounded)).foregroundColor(Theme.text)
            Spacer()
            if let t = trailing { Text(t).font(.caption).foregroundColor(Theme.dim) }
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
    }
}

struct CategoryIcon: View {
    var category: Category
    var size: CGFloat = 36
    var body: some View {
        ZStack {
            Circle().fill(Color(hex: category.colorHex).opacity(0.18))
            Image(systemName: category.symbol)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundColor(Color(hex: category.colorHex))
        }
        .frame(width: size, height: size)
    }
}

struct AmountText: View {
    var value: Double
    var signed = false
    var paise = true
    var font: Font = .system(.body, design: .rounded).weight(.semibold)
    var body: some View {
        Text(signed ? Money.signed(value, paise: paise) : Money.format(value, paise: paise))
            .font(font)
            .monospacedDigit()
            .foregroundColor(signed ? Theme.pnl(value) : Theme.text)
    }
}

struct Pill: View {
    var text: String
    var color: Color = Theme.gold
    var filled = false
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundColor(filled ? .black : color)
            .background(Capsule().fill(filled ? color : color.opacity(0.14)))
            .overlay(Capsule().stroke(color.opacity(filled ? 0 : 0.35), lineWidth: 1))
    }
}

/// Horizontal list of choices (chart types etc.).
struct ChipPicker<T: Hashable>: View {
    var items: [T]
    @Binding var selection: T
    var label: (T) -> String
    var symbol: ((T) -> String)? = nil
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    Button {
                        Haptic.tap()
                        withAnimation(.easeInOut(duration: 0.2)) { selection = item }
                    } label: {
                        HStack(spacing: 5) {
                            if let s = symbol?(item) { Image(systemName: s).font(.caption) }
                            Text(label(item)).font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .foregroundColor(selection == item ? .black : Theme.dim)
                        .background(Capsule().fill(selection == item ? Theme.gold : Theme.cardRaised))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

struct MonthSwitcher: View {
    @Binding var month: Date
    var body: some View {
        HStack {
            Button { Haptic.tap(); month = Cal.addMonths(-1, to: month) } label: {
                Image(systemName: "chevron.left").font(.headline).frame(width: 36, height: 36)
            }
            Spacer()
            VStack(spacing: 1) {
                Text(Cal.monthTitleFormatter.string(from: month)).font(.system(.headline, design: .rounded))
                Text("\(MonthSwitcher.ordinal(1)) – \(MonthSwitcher.ordinal(Cal.daysInMonth(month)))").font(.caption2).foregroundColor(Theme.faint)
            }
            Spacer()
            Button { Haptic.tap(); month = Cal.addMonths(1, to: month) } label: {
                Image(systemName: "chevron.right").font(.headline).frame(width: 36, height: 36)
            }
            .disabled(Cal.sameMonth(month, Date()) || month > Date())
        }
        .foregroundColor(Theme.gold)
    }

    /// 1st, 2nd, 3rd, 4th … 11th, 12th, 13th … 21st, 22nd, 23rd … 31st.
    static func ordinal(_ n: Int) -> String {
        if (11...13).contains(n % 100) { return "\(n)th" }
        switch n % 10 {
        case 1: return "\(n)st"
        case 2: return "\(n)nd"
        case 3: return "\(n)rd"
        default: return "\(n)th"
        }
    }
}

struct EmptyNote: View {
    var symbol: String
    var title: String
    var detail: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundColor(Theme.goldDeep)
            Text(title).font(.headline)
            Text(detail).font(.footnote).foregroundColor(Theme.dim).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

struct StatTile: View {
    var title: String
    var value: String
    var color: Color = Theme.text
    var sub: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundColor(Theme.dim)
            Text(value).font(.system(.subheadline, design: .rounded).weight(.semibold)).foregroundColor(color).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            if let s = sub { Text(s).font(.caption2).foregroundColor(Theme.faint).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardRaised))
    }
}

/// A donut drawn by hand (Swift Charts on iOS 16 has no sector marks).
struct DonutSlice: Identifiable {
    var id: String
    var value: Double
    var color: Color
    var label: String
}

struct DonutChart<Center: View>: View {
    var slices: [DonutSlice]
    var thickness: CGFloat = 0.2
    @ViewBuilder var center: () -> Center

    private struct Arc: Identifiable {
        var id: String
        var start: Angle
        var end: Angle
        var color: Color
    }

    private var arcs: [Arc] {
        let total = slices.reduce(0) { $0 + max(0, $1.value) }
        guard total > 0 else { return [] }
        var a = -90.0
        let gap = slices.count > 1 ? 1.2 : 0
        return slices.map { s in
            let sweep = max(0, s.value) / total * 360
            let arc = Arc(id: s.id, start: .degrees(a + gap / 2), end: .degrees(a + max(sweep - gap / 2, gap / 2 + 0.1)), color: s.color)
            a += sweep
            return arc
        }
    }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let lw = size * thickness
            ZStack {
                Circle().stroke(Theme.cardRaised, lineWidth: lw).padding(lw / 2)
                ForEach(arcs) { arc in
                    ArcShape(start: arc.start, end: arc.end)
                        .stroke(arc.color, style: StrokeStyle(lineWidth: lw, lineCap: .butt))
                        .padding(lw / 2)
                }
                center()
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ArcShape: Shape {
    var start: Angle
    var end: Angle
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2,
                 startAngle: start, endAngle: end, clockwise: false)
        return p
    }
}

/// Legend rows under a donut.
struct LegendRow: View {
    var color: Color
    var label: String
    var value: String
    var share: Double?
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).font(.footnote).lineLimit(1)
            Spacer()
            if let s = share { Text(String(format: "%.0f%%", s * 100)).font(.caption).foregroundColor(Theme.dim).monospacedDigit() }
            Text(value).font(.footnote.weight(.semibold)).monospacedDigit()
        }
    }
}
