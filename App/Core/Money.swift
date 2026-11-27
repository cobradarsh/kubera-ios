import Foundation

/// Rupee formatting with Indian digit grouping (₹1,23,45,678.90) and short forms (₹12.3K, ₹4.5L, ₹1.2Cr).
enum Money {
    static let locale = Locale(identifier: "en_IN")

    private static let full: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .currency
        f.currencyCode = "INR"
        f.currencySymbol = "₹"
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        return f
    }()

    private static let whole: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .currency
        f.currencyCode = "INR"
        f.currencySymbol = "₹"
        f.maximumFractionDigits = 0
        return f
    }()

    private static let plain: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        return f
    }()

    /// ₹1,23,456.5 (paise only when present).
    static func format(_ v: Double, paise: Bool = true) -> String {
        let f = paise ? full : whole
        return f.string(from: NSNumber(value: v)) ?? "₹\(v)"
    }

    /// +₹1,234 / −₹1,234 for profit and loss.
    static func signed(_ v: Double, paise: Bool = false) -> String {
        let s = format(abs(v), paise: paise)
        if v > 0.004 { return "+" + s }
        if v < -0.004 { return "−" + s }
        return s
    }

    /// ₹950, ₹12.3K, ₹4.56L, ₹1.23Cr.
    static func compact(_ v: Double) -> String {
        let a = abs(v)
        let sign = v < 0 ? "−" : ""
        func trim(_ x: Double, _ digits: Int) -> String {
            var s = String(format: "%.\(digits)f", x)
            if s.contains(".") {
                while s.hasSuffix("0") { s.removeLast() }
                if s.hasSuffix(".") { s.removeLast() }
            }
            return s
        }
        if a >= 1_00_00_000 { return "\(sign)₹\(trim(a / 1_00_00_000, 2))Cr" }
        if a >= 1_00_000 { return "\(sign)₹\(trim(a / 1_00_000, 2))L" }
        if a >= 1_000 { return "\(sign)₹\(trim(a / 1_000, 1))K" }
        return "\(sign)₹\(trim(a, 0))"
    }

    static func number(_ v: Double) -> String {
        plain.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    /// "1,23,456.78" / "1234" / "-1234.500" -> Double. Accepts Unicode minus.
    static func parse(_ s: String) -> Double? {
        var t = s.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: " ", with: "")
        while t.hasSuffix(".") { t.removeLast() }
        return Double(t)
    }
}

/// Calendar helpers. Months start on the 1st; everything is in India time.
enum Cal {
    static let ist = TimeZone(identifier: "Asia/Kolkata") ?? .current

    static var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = ist
        c.locale = Locale(identifier: "en_IN")
        c.firstWeekday = 2 // Monday
        return c
    }()

    static func startOfDay(_ d: Date) -> Date { cal.startOfDay(for: d) }

    static func startOfMonth(_ d: Date) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
    }

    static func endOfMonth(_ d: Date) -> Date {
        cal.date(byAdding: DateComponents(month: 1, second: -1), to: startOfMonth(d)) ?? d
    }

    static func addMonths(_ n: Int, to d: Date) -> Date {
        cal.date(byAdding: .month, value: n, to: d) ?? d
    }

    static func addDays(_ n: Int, to d: Date) -> Date {
        cal.date(byAdding: .day, value: n, to: d) ?? d
    }

    static func daysInMonth(_ d: Date) -> Int {
        cal.range(of: .day, in: .month, for: d)?.count ?? 30
    }

    static func day(_ d: Date) -> Int { cal.component(.day, from: d) }
    static func month(_ d: Date) -> Int { cal.component(.month, from: d) }
    static func year(_ d: Date) -> Int { cal.component(.year, from: d) }
    static func hour(_ d: Date) -> Int { cal.component(.hour, from: d) }
    /// 1 = Monday … 7 = Sunday.
    static func weekdayMon(_ d: Date) -> Int {
        let w = cal.component(.weekday, from: d) // 1 = Sunday
        return w == 1 ? 7 : w - 1
    }

    static func sameDay(_ a: Date, _ b: Date) -> Bool { cal.isDate(a, inSameDayAs: b) }
    static func sameMonth(_ a: Date, _ b: Date) -> Bool {
        cal.isDate(a, equalTo: b, toGranularity: .month)
    }

    static func make(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0) -> Date? {
        cal.date(from: DateComponents(timeZone: ist, year: y, month: m, day: d, hour: h, minute: min, second: s))
    }

    private static func fmt(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_IN")
        f.timeZone = ist
        f.dateFormat = pattern
        return f
    }
    static let dayKeyFormatter = fmt("yyyy-MM-dd")
    static let monthTitleFormatter = fmt("MMMM yyyy")
    static let shortMonthFormatter = fmt("MMM")
    static let dayTitleFormatter = fmt("EEE, d MMM")
    static let timeFormatter = fmt("h:mm a")
    static let dayMonthFormatter = fmt("d MMM")
    static let fullFormatter = fmt("d MMM yyyy, h:mm a")
    static let weekdayFormatter = fmt("EEEE")

    static func dayKey(_ d: Date) -> String { dayKeyFormatter.string(from: d) }
    static func fromDayKey(_ s: String) -> Date? { dayKeyFormatter.date(from: s) }
}
