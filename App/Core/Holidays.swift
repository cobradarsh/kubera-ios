import Foundation

/// NSE trading holidays and India's gazetted holidays.
///
/// Sources (checked 27 Nov 2026):
/// - NSE trading holidays 2026, equity and equity-derivatives segments (NSE circular of Dec 2025, as listed by
///   Upstox "verified by the NSE circular"), plus the extra closure on 15 Jan 2026 for the Maharashtra municipal
///   elections (NSE circular of Jan 2026, widely reported).
/// - Gazetted holidays 2026 for central government offices: DoPT OM No. F.No.12/2/2023-JCA dated 3 July 2025.
/// NSE usually publishes the next year's list in mid-December; Settings → Holidays can add days by hand.
enum Holidays {
    private static func d(_ s: String) -> Date { Cal.fromDayKey(s) ?? Date.distantPast }

    static let nse2026: [Holiday] = [
        Holiday(date: d("2026-01-15"), name: "Municipal Corporation elections (Maharashtra)", kind: .special, note: "Extra closure announced in Jan 2026"),
        Holiday(date: d("2026-01-26"), name: "Republic Day", kind: .nse),
        Holiday(date: d("2026-02-15"), name: "Mahashivratri", kind: .nse, note: "Sunday"),
        Holiday(date: d("2026-03-03"), name: "Holi", kind: .nse),
        Holiday(date: d("2026-03-21"), name: "Id-Ul-Fitr (Ramadan Eid)", kind: .nse, note: "Saturday"),
        Holiday(date: d("2026-03-26"), name: "Shri Ram Navami", kind: .nse),
        Holiday(date: d("2026-03-31"), name: "Shri Mahavir Jayanti", kind: .nse),
        Holiday(date: d("2026-04-03"), name: "Good Friday", kind: .nse),
        Holiday(date: d("2026-04-14"), name: "Dr. Baba Saheb Ambedkar Jayanti", kind: .nse),
        Holiday(date: d("2026-05-01"), name: "Maharashtra Day", kind: .nse),
        Holiday(date: d("2026-05-28"), name: "Bakri Id", kind: .nse),
        Holiday(date: d("2026-06-26"), name: "Muharram", kind: .nse),
        Holiday(date: d("2026-08-15"), name: "Independence Day", kind: .nse, note: "Saturday"),
        Holiday(date: d("2026-09-14"), name: "Ganesh Chaturthi", kind: .nse),
        Holiday(date: d("2026-10-02"), name: "Mahatma Gandhi Jayanti", kind: .nse),
        Holiday(date: d("2026-10-20"), name: "Dussehra", kind: .nse),
        Holiday(date: d("2026-11-08"), name: "Diwali Laxmi Pujan", kind: .nse, note: "Sunday; Muhurat trading session"),
        Holiday(date: d("2026-11-10"), name: "Diwali Balipratipada", kind: .nse),
        Holiday(date: d("2026-11-24"), name: "Prakash Gurpurb Sri Guru Nanak Dev", kind: .nse),
        Holiday(date: d("2026-12-25"), name: "Christmas", kind: .nse),
    ]

    static let india2026: [Holiday] = [
        Holiday(date: d("2026-01-26"), name: "Republic Day", kind: .india),
        Holiday(date: d("2026-03-04"), name: "Holi", kind: .india),
        Holiday(date: d("2026-03-21"), name: "Id-ul-Fitr", kind: .india),
        Holiday(date: d("2026-03-26"), name: "Ram Navami", kind: .india),
        Holiday(date: d("2026-03-31"), name: "Mahavir Jayanti", kind: .india),
        Holiday(date: d("2026-04-03"), name: "Good Friday", kind: .india),
        Holiday(date: d("2026-05-01"), name: "Buddha Purnima", kind: .india),
        Holiday(date: d("2026-05-27"), name: "Id-ul-Zuha (Bakrid)", kind: .india),
        Holiday(date: d("2026-06-26"), name: "Muharram", kind: .india),
        Holiday(date: d("2026-08-15"), name: "Independence Day", kind: .india),
        Holiday(date: d("2026-08-26"), name: "Milad-un-Nabi (Id-e-Milad)", kind: .india),
        Holiday(date: d("2026-09-04"), name: "Janmashtami (Vaishnava)", kind: .india),
        Holiday(date: d("2026-10-02"), name: "Mahatma Gandhi's Birthday", kind: .india),
        Holiday(date: d("2026-10-20"), name: "Dussehra", kind: .india),
        Holiday(date: d("2026-11-08"), name: "Diwali (Deepavali)", kind: .india),
        Holiday(date: d("2026-11-24"), name: "Guru Nanak's Birthday", kind: .india),
        Holiday(date: d("2026-12-25"), name: "Christmas Day", kind: .india),
    ]

    /// Weekend days on which NSE held a session.
    static let specialSessions: [Holiday] = [
        Holiday(date: d("2026-02-01"), name: "Union Budget: special trading session", kind: .special, note: "Sunday"),
        Holiday(date: d("2026-11-08"), name: "Muhurat trading (Diwali)", kind: .special, note: "Evening session"),
    ]

    static var builtIn: [Holiday] { nse2026 + india2026 }

    /// Whether NSE's equity / F&O market trades on that day (weekends, NSE holidays and extra closures excluded).
    static func isTradingDay(_ date: Date, extra: [Holiday] = []) -> Bool {
        let key = Cal.dayKey(date)
        if specialSessions.contains(where: { Cal.dayKey($0.date) == key }) { return true }
        let wd = Cal.weekdayMon(date)
        if wd >= 6 { return false }
        let closed = (nse2026 + extra).contains { ($0.kind == .nse || $0.kind == .special) && Cal.dayKey($0.date) == key }
        return !closed
    }

    static func previousTradingDay(before date: Date, extra: [Holiday] = []) -> Date {
        var d = Cal.startOfDay(Cal.addDays(-1, to: date))
        for _ in 0..<15 {
            if isTradingDay(d, extra: extra) { return d }
            d = Cal.addDays(-1, to: d)
        }
        return d
    }

    /// The trading day a screenshot taken at `date` belongs to: before 09:00, or on a closed day, it is the
    /// previous trading day's result.
    ///
    /// `commodity`: the screen shows MCX contracts. MCX's evening session (17:00 to about 23:55) also runs on most NSE
    /// weekday holidays, so an evening screenshot on such a day, or one taken before 09:00 the next morning, belongs
    /// to that day.
    static func tradingDay(forScreenshotAt date: Date, extra: [Holiday] = [], commodity: Bool = false) -> Date {
        let day = Cal.startOfDay(date)
        if commodity {
            let early = Cal.hour(date) < 9
            let session = early ? Cal.addDays(-1, to: day) : day
            if isTradingDay(session, extra: extra) { return session }
            if isWeekday(session) && (early || Cal.hour(date) >= 17) { return session }
            return previousTradingDay(before: session, extra: extra)
        }
        if Cal.hour(date) < 9 { return previousTradingDay(before: day, extra: extra) }
        if isTradingDay(day, extra: extra) { return day }
        return previousTradingDay(before: day, extra: extra)
    }

    static func isWeekday(_ date: Date) -> Bool { Cal.weekdayMon(date) < 6 }

    /// Market status line for the header.
    static func marketStatus(at now: Date = Date(), extra: [Holiday] = []) -> String {
        let day = Cal.startOfDay(now)
        if !isTradingDay(day, extra: extra) {
            if let h = (nse2026 + extra).first(where: { Cal.sameDay($0.date, day) }) { return "Market closed: \(h.name)" }
            return "Market closed: weekend"
        }
        let mins = Cal.hour(now) * 60 + Cal.cal.component(.minute, from: now)
        if mins < 9 * 60 { return "Pre-market" }
        if mins < 9 * 60 + 15 { return "Pre-open session" }
        if mins < 15 * 60 + 30 { return "Market open" }
        return "Market closed for the day"
    }

    static func next(_ list: [Holiday], after now: Date = Date()) -> Holiday? {
        let today = Cal.startOfDay(now)
        return list.filter { $0.date >= today }.sorted { $0.date < $1.date }.first
    }
}
