import Foundation

/// Human-friendly scheduling that compiles to cron — most people shouldn't
/// have to know what `0 */6 * * *` means.
enum Schedule: Equatable {
    case everyNHours(Int)             // every 6 hours
    case everyNMinutes(Int)           // every 30 minutes
    case dailyAt(hour: Int, minute: Int)
    case weekdaysAt(hour: Int, minute: Int)
    case weeklyOn(weekday: Int, hour: Int, minute: Int)   // 0 = Sunday
    case monthlyOn(day: Int, hour: Int, minute: Int)
    case custom(String)

    // MARK: → cron

    var cron: String {
        switch self {
        case .everyNMinutes(let n): "*/\(max(1, min(59, n))) * * * *"
        case .everyNHours(let n):   "0 */\(max(1, min(23, n))) * * *"
        case .dailyAt(let h, let m): "\(m) \(h) * * *"
        case .weekdaysAt(let h, let m): "\(m) \(h) * * 1-5"
        case .weeklyOn(let d, let h, let m): "\(m) \(h) * * \(d)"
        case .monthlyOn(let day, let h, let m): "\(m) \(h) \(day) * *"
        case .custom(let expr): expr
        }
    }

    // MARK: ← cron (best-effort, for editing existing jobs)

    static func from(cron: String) -> Schedule {
        let parts = cron.split(separator: " ").map(String.init)
        guard parts.count == 5 else { return .custom(cron) }
        let (minute, hour, dom, month, dow) = (parts[0], parts[1], parts[2], parts[3], parts[4])

        if minute.hasPrefix("*/"), hour == "*", dom == "*", month == "*", dow == "*",
           let n = Int(minute.dropFirst(2)) {
            return .everyNMinutes(n)
        }
        if hour.hasPrefix("*/"), dom == "*", month == "*", dow == "*",
           let n = Int(hour.dropFirst(2)), let m = Int(minute), m == 0 {
            return .everyNHours(n)
        }
        guard let m = Int(minute), let h = Int(hour) else { return .custom(cron) }

        if dom == "*", month == "*" {
            if dow == "*" { return .dailyAt(hour: h, minute: m) }
            if dow == "1-5" { return .weekdaysAt(hour: h, minute: m) }
            if let d = Int(dow) { return .weeklyOn(weekday: d, hour: h, minute: m) }
        }
        if month == "*", dow == "*", let d = Int(dom) {
            return .monthlyOn(day: d, hour: h, minute: m)
        }
        return .custom(cron)
    }

    // MARK: Description

    /// Plain-English summary, e.g. "Every day at 5:00 PM".
    var summary: String {
        func time(_ h: Int, _ m: Int) -> String {
            var comps = DateComponents(); comps.hour = h; comps.minute = m
            let date = Calendar.current.date(from: comps) ?? .now
            let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
            return f.string(from: date)
        }
        switch self {
        case .everyNMinutes(let n): return n == 1 ? "Every minute" : "Every \(n) minutes"
        case .everyNHours(let n):   return n == 1 ? "Every hour" : "Every \(n) hours"
        case .dailyAt(let h, let m): return "Every day at \(time(h, m))"
        case .weekdaysAt(let h, let m): return "Weekdays at \(time(h, m))"
        case .weeklyOn(let d, let h, let m):
            return "Every \(Self.weekdayNames[d % 7]) at \(time(h, m))"
        case .monthlyOn(let day, let h, let m):
            return "Monthly on day \(day) at \(time(h, m))"
        case .custom(let expr): return "Custom (\(expr))"
        }
    }

    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday",
                               "Thursday", "Friday", "Saturday"]

    // MARK: Editing helpers

    enum Kind: String, CaseIterable, Identifiable {
        case everyNHours = "Every few hours"
        case dailyAt = "Once a day"
        case weekdaysAt = "Weekdays only"
        case weeklyOn = "Once a week"
        case monthlyOn = "Once a month"
        case everyNMinutes = "Every few minutes"
        case custom = "Custom (cron)"
        var id: String { rawValue }
    }

    var kind: Kind {
        switch self {
        case .everyNHours: .everyNHours
        case .everyNMinutes: .everyNMinutes
        case .dailyAt: .dailyAt
        case .weekdaysAt: .weekdaysAt
        case .weeklyOn: .weeklyOn
        case .monthlyOn: .monthlyOn
        case .custom: .custom
        }
    }

    var hour: Int {
        switch self {
        case .dailyAt(let h, _), .weekdaysAt(let h, _),
             .weeklyOn(_, let h, _), .monthlyOn(_, let h, _): h
        default: 9
        }
    }
    var minute: Int {
        switch self {
        case .dailyAt(_, let m), .weekdaysAt(_, let m),
             .weeklyOn(_, _, let m), .monthlyOn(_, _, let m): m
        default: 0
        }
    }
    var interval: Int {
        switch self {
        case .everyNHours(let n): n
        case .everyNMinutes(let n): n
        default: 6
        }
    }
    var weekday: Int { if case .weeklyOn(let d, _, _) = self { return d }; return 1 }
    var monthDay: Int { if case .monthlyOn(let d, _, _) = self { return d }; return 1 }

    /// Rebuilds a schedule when the user switches kind, preserving what fits.
    func changing(to kind: Kind) -> Schedule {
        switch kind {
        case .everyNHours: .everyNHours(interval == 0 ? 6 : min(interval, 23))
        case .everyNMinutes: .everyNMinutes(max(5, min(interval, 59)))
        case .dailyAt: .dailyAt(hour: hour, minute: minute)
        case .weekdaysAt: .weekdaysAt(hour: hour, minute: minute)
        case .weeklyOn: .weeklyOn(weekday: weekday, hour: hour, minute: minute)
        case .monthlyOn: .monthlyOn(day: monthDay, hour: hour, minute: minute)
        case .custom: .custom(cron)
        }
    }
}
