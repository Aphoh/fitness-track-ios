import Foundation

/// "YYYY-MM-DD" local-date helpers. FitnessTrack stores dates as plain local
/// date strings; day_of_week is 0 = Monday … 6 = Sunday throughout.
public enum LocalDate {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    public static func string(from date: Date, timeZone: TimeZone = .current) -> String {
        var c = Calendar(identifier: .gregorian); c.timeZone = timeZone
        let d = c.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", d.year!, d.month!, d.day!)
    }

    public static func today() -> String { string(from: Date()) }

    public static func parse(_ s: String) -> Date? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    public static func addDays(_ s: String, _ n: Int) -> String {
        guard let d = parse(s), let r = calendar.date(byAdding: .day, value: n, to: d) else { return s }
        return string(from: r, timeZone: calendar.timeZone)
    }

    /// 0 = Monday … 6 = Sunday.
    public static func dayOfWeek(_ s: String) -> Int {
        guard let d = parse(s) else { return 0 }
        return (calendar.component(.weekday, from: d) + 5) % 7
    }

    /// Monday of the week containing `s`.
    public static func weekStart(_ s: String) -> String { addDays(s, -dayOfWeek(s)) }

    /// The date at local noon (for charts, which bucket in the current time zone).
    public static func chartDate(_ s: String) -> Date {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return .now }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12)) ?? .now
    }

    public static let dayShort = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    public static let dayLong = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    public static func display(_ s: String?, format: String = "MMM d") -> String {
        guard let s, let d = parse(s) else { return "—" }
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate(format)
        return f.string(from: d)
    }
}
