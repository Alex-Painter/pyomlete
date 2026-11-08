import Foundation

/// What the phone's calendar says about each evening. A port of the web's
/// `client/src/lib/calendarDays.ts`.
///
/// The calendar only suggests: this reads busy blocks and says what they mean
/// for dinner, and nothing here writes to a list. A busy evening is shown on
/// the week and leaves the day alone; Out and Quick night stay the person's own
/// taps. Times are local to `calendar`, so a week across the clocks changing
/// still lines up.
nonisolated enum CalendarDays {
    struct BusyBlock: Equatable, Sendable {
        let start: Date
        let end: Date
    }

    /// When dinner happens, as "HH:MM" local times.
    struct DinnerWindow: Equatable, Sendable {
        var start = "18:00"
        var end = "20:30"
    }

    enum Evening: Equatable, Sendable {
        case free
        /// Busy the whole day: likely away.
        case away(String)
        /// Busy across the whole dinner window.
        case out(String)
        /// Busy for part of it: a quick dinner fits.
        case quick(String)

        var reason: String? {
            switch self {
            case .free: nil
            case .away(let reason), .out(let reason), .quick(let reason): reason
            }
        }

        /// The calendar says there is no dinner at home.
        var isBusy: Bool {
            switch self {
            case .away, .out: true
            case .free, .quick: false
            }
        }
    }

    /// With this much free time in the window, the evening counts as free.
    static let enoughMinutes = 120

    private static func local(_ date: PlanDate, plusDays: Int = 0, time: String = "00:00", in calendar: Calendar) -> Date {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        var components = DateComponents(year: date.year, month: date.month, day: date.day + plusDays)
        components.hour = parts.first ?? 0
        components.minute = parts.count > 1 ? parts[1] : 0
        return calendar.date(from: components)!
    }

    /// "19:30", local.
    private static func clock(_ date: Date, in calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// The week's span, local midnight to local midnight.
    static func weekRange(_ days: [PlanDay], calendar: Calendar = .current) -> (start: Date, end: Date)? {
        guard let first = days.first, let last = days.last else { return nil }
        return (local(first.date, in: calendar), local(last.date, plusDays: 1, in: calendar))
    }

    static func evening(_ busy: [BusyBlock], on date: PlanDate, dinner: DinnerWindow, calendar: Calendar = .current) -> Evening {
        let dayStart = local(date, in: calendar)
        let dayEnd = local(date, plusDays: 1, in: calendar)
        let from = local(date, time: dinner.start, in: calendar)
        let to = local(date, time: dinner.end, in: calendar)
        let blocks = busy.filter { $0.end > from && $0.start < to }.sorted { $0.start < $1.start }
        guard !blocks.isEmpty else { return .free }

        if blocks.contains(where: { $0.start <= dayStart && $0.end >= dayEnd }) { return .away("Away all day") }
        if let whole = blocks.first(where: { $0.start <= from && $0.end >= to }) {
            let start = max(whole.start, dayStart)
            let end = min(whole.end, dayEnd)
            if start == dayStart || end == dayEnd {
                return .out(start == dayStart ? "Busy until \(clock(end, in: calendar))" : "Busy from \(clock(start, in: calendar))")
            }
            return .out("Busy \(clock(start, in: calendar))–\(clock(end, in: calendar))")
        }

        // The longest stretch of the window with nothing on.
        var longest: TimeInterval = 0
        var cursor = from
        for block in blocks {
            longest = max(longest, block.start.timeIntervalSince(cursor))
            cursor = max(cursor, block.end)
        }
        longest = max(longest, to.timeIntervalSince(cursor))
        if longest >= TimeInterval(enoughMinutes * 60) { return .free }

        let first = blocks[0]
        return .quick(first.start <= from ? "Back at \(clock(first.end, in: calendar))" : "Out at \(clock(first.start, in: calendar))")
    }

    /// Each day's evening, by date.
    static func week(_ busy: [BusyBlock], days: [PlanDay], dinner: DinnerWindow, calendar: Calendar = .current) -> [PlanDate: Evening] {
        Dictionary(uniqueKeysWithValues: days.map { ($0.date, evening(busy, on: $0.date, dinner: dinner, calendar: calendar)) })
    }
}
