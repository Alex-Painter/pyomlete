import Foundation

/// A calendar date with no time of day and no zone, as the server's week days
/// are. Held as whole days since 1970-01-01, so every step is integer days and
/// a clocks change can never make a day 23 hours long and skip a date.
nonisolated struct PlanDate: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    let daysSince1970: Int

    init(daysSince1970: Int) {
        self.daysSince1970 = daysSince1970
    }

    init(year: Int, month: Int, day: Int) {
        // Howard Hinnant's days_from_civil.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        daysSince1970 = era * 146_097 + dayOfEra - 719_468
    }

    /// `YYYY-MM-DD`, and only a date that exists.
    init?(iso: String) {
        let parts = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        self.init(year: year, month: month, day: day)
        guard self.month == month, self.day == day else { return nil }
    }

    /// Today on this device's calendar, not UTC's.
    static func today(now: Date = .now, calendar: Calendar = .current) -> PlanDate {
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return PlanDate(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    func adding(days: Int) -> PlanDate {
        PlanDate(daysSince1970: daysSince1970 + days)
    }

    /// Whole days from this date to `other`; negative when `other` is earlier.
    func days(to other: PlanDate) -> Int {
        other.daysSince1970 - daysSince1970
    }

    /// 0 is Monday, matching the server's `week_start_weekday`.
    var weekday: Int {
        // 1970-01-01 was a Thursday.
        ((daysSince1970 + 3) % 7 + 7) % 7
    }

    var year: Int { civil.year }
    var month: Int { civil.month }
    var day: Int { civil.day }

    var iso: String {
        let (year, month, day) = civil
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    var description: String { iso }

    static func < (lhs: PlanDate, rhs: PlanDate) -> Bool {
        lhs.daysSince1970 < rhs.daysSince1970
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let date = PlanDate(iso: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a date: \(text)")
        }
        self = date
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(iso)
    }

    /// Howard Hinnant's civil_from_days.
    private var civil: (year: Int, month: Int, day: Int) {
        let z = daysSince1970 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shifted = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shifted + 2) / 5 + 1
        let month = shifted < 10 ? shifted + 3 : shifted - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }
}

nonisolated extension PlanDate {
    private static let shortDays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let longDays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    private static let shortMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let longMonths = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    /// "Tue"
    var dayShort: String { Self.shortDays[weekday] }
    /// "Tuesday"
    var dayLong: String { Self.longDays[weekday] }
    /// "Monday" for 0, as the server numbers weekdays.
    static func weekdayLong(_ weekday: Int) -> String { longDays[weekday] }
    /// "Tue 20 Oct"
    var shortLabel: String { "\(dayShort) \(day) \(Self.shortMonths[month - 1])" }
    /// "August"
    var monthLong: String { Self.longMonths[month - 1] }
    /// "20 October"
    var longDate: String { "\(day) \(Self.longMonths[month - 1])" }
}

/// What one evening holds. A meal wins over Out, as on the server, so a day
/// that is both cannot be written down.
nonisolated enum DayPlan: Codable, Hashable, Sendable {
    case meal(RecipeID)
    case open
    case out

    var meal: RecipeID? {
        if case .meal(let recipe) = self { recipe } else { nil }
    }
}

nonisolated struct PlanDay: Codable, Hashable, Sendable, Identifiable {
    let date: PlanDate
    var plan: DayPlan
    /// A quick night: dinners over 30 minutes sink in the fit score. It belongs
    /// to the evening, so it stays when a meal goes on or comes off.
    var quick = false

    var id: PlanDate { date }
}

/// A day saved by a build from before quick nights has none.
nonisolated extension PlanDay {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(PlanDate.self, forKey: .date)
        plan = try container.decode(DayPlan.self, forKey: .plan)
        quick = try container.decodeIfPresent(Bool.self, forKey: .quick) ?? false
    }
}

/// Settings > Planning the week, from `/api/settings/plan`.
nonisolated struct PlanSettings: Codable, Equatable, Sendable {
    static let defaultVarietyDays = 3
    static let varietyRange = 1...7

    /// 0 is Monday. Saturday by default: the week runs from one shop to the next.
    var weekStartWeekday: Int
    /// How many days a base (pasta, rice...) stays off the menu after it is had.
    var varietyDays: Int

    /// "Pasta on Monday ranks pasta lower until Thursday."
    var untilWeekday: String {
        PlanDate.weekdayLong((varietyDays + 1) % 7)
    }
}

/// The week's rules that are not about one day, apart from any screen.
nonisolated enum Week {
    /// Today when it is in the week, else the first evening still to plan, else the first.
    static func defaultDay(_ days: [PlanDay], today: PlanDate) -> PlanDate? {
        if days.contains(where: { $0.date == today }) { return today }
        return (days.first { $0.plan == .open } ?? days.first)?.date
    }

    /// The next evening still to plan after `from`, wrapping round the week, so
    /// filling a week is one tap per dinner. Stays on `from` when none is left.
    /// `skip` passes over evenings the calendar says you're out.
    static func nextOpenDay(_ days: [PlanDay], from: PlanDate, skip: (PlanDate) -> Bool = { _ in false }) -> PlanDate {
        guard let start = days.firstIndex(where: { $0.date == from }) else { return from }
        for step in 1..<days.count {
            let day = days[(start + step) % days.count]
            if day.plan == .open, !skip(day.date) { return day.date }
        }
        return from
    }

    /// Saturday, the server's own default, for a phone that has never been told.
    static let defaultStartWeekday = 5

    /// The most recent `weekday` on or before `today`.
    static func start(for today: PlanDate, weekday: Int) -> PlanDate {
        today.adding(days: -((today.weekday - weekday + 7) % 7))
    }

    /// The week "Plan a week" opens: this one, or next week on the last day of
    /// this one, when it is all but over. The list already made for that week,
    /// if any, is opened rather than a second one made.
    static func toPlan(today: PlanDate, weekday: Int, lists: [ListSummary]) -> (start: PlanDate, list: ListID?) {
        let current = start(for: today, weekday: weekday)
        let start = current.days(to: today) == 6 ? current.adding(days: 7) : current
        return (start, lists.first { $0.weekStart == start }?.id)
    }

    /// The weeks New list offers: the one Plan a week opens and the next two,
    /// so a week can be planned ahead. Each carries its list when one is
    /// already made, which is opened rather than a second copy made.
    static func ahead(
        today: PlanDate, weekday: Int, lists: [ListSummary], count: Int = 3
    ) -> [(start: PlanDate, list: ListID?)] {
        let first = toPlan(today: today, weekday: weekday, lists: lists).start
        return (0..<count).map { n in
            let start = first.adding(days: 7 * n)
            return (start, lists.first { $0.weekStart == start }?.id)
        }
    }

    /// "This week, Sat 31 Oct", "Next week, Sat 7 Nov", then "Week of Sat 14
    /// Nov", with "Open" in front when the week already has a list.
    static func choiceLabel(start: PlanDate, hasList: Bool, today: PlanDate, weekday: Int) -> String {
        let ahead = Self.start(for: today, weekday: weekday).days(to: start) / 7
        let name = switch ahead {
        case 0: "this week, \(start.shortLabel)"
        case 1: "next week, \(start.shortLabel)"
        default: "week of \(start.shortLabel)"
        }
        return hasList ? "Open \(name)" : name.prefix(1).uppercased() + name.dropFirst()
    }
}
