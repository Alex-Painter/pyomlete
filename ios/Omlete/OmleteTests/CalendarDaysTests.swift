import EventKit
import Foundation
import Testing
@testable import Omlete

/// The web's `calendarDays.test.ts`, case for case, in London time: BST is
/// UTC+1 until the clocks go back on 25 Oct 2026.
struct CalendarDaysTests {
    private let dinner = CalendarDays.DinnerWindow(start: "18:00", end: "20:30")
    private let london: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    private func block(_ start: String, _ end: String) -> CalendarDays.BusyBlock {
        CalendarDays.BusyBlock(start: try! Date(start, strategy: .iso8601), end: try! Date(end, strategy: .iso8601))
    }

    private func evening(_ busy: [CalendarDays.BusyBlock], _ iso: String) -> CalendarDays.Evening {
        CalendarDays.evening(busy, on: PlanDate(iso: iso)!, dinner: dinner, calendar: london)
    }

    @Test func freeWithNothingOnOrSomethingOnlyInTheAfternoon() {
        #expect(evening([], "2026-10-20") == .free)
        #expect(evening([block("2026-10-20T13:00:00Z", "2026-10-20T16:00:00Z")], "2026-10-20") == .free)
    }

    @Test func outWhenBusyAcrossTheWholeDinnerWindow() {
        #expect(evening([block("2026-10-20T16:30:00Z", "2026-10-20T21:00:00Z")], "2026-10-20") == .out("Busy 17:30–22:00"))
    }

    @Test func awayWhenBusyTheWholeDay() {
        #expect(evening([block("2026-10-19T23:00:00Z", "2026-10-20T23:00:00Z")], "2026-10-20") == .away("Away all day"))
    }

    @Test func saysWhenABusyStretchOverTheWindowRunsIntoTheNight() {
        #expect(evening([block("2026-10-20T13:00:00Z", "2026-10-21T08:00:00Z")], "2026-10-20") == .out("Busy from 14:00"))
    }

    @Test func quickWhenBackLateOrOutEarly() {
        #expect(evening([block("2026-10-20T15:00:00Z", "2026-10-20T18:00:00Z")], "2026-10-20") == .quick("Back at 19:00"))
        #expect(evening([block("2026-10-20T18:30:00Z", "2026-10-20T21:00:00Z")], "2026-10-20") == .quick("Out at 19:30"))
    }

    @Test func staysFreeWhenAShortCallLeavesTwoHours() {
        #expect(evening([block("2026-10-20T19:00:00Z", "2026-10-20T19:30:00Z")], "2026-10-20") == .free)
    }

    @Test func readsLocalTimeAfterTheClocksGoBack() {
        #expect(evening([block("2026-10-27T17:00:00Z", "2026-10-27T19:00:00Z")], "2026-10-27") == .quick("Back at 19:00"))
        // Away on the day the clocks change, which is 25 hours long.
        #expect(evening([block("2026-10-24T23:00:00Z", "2026-10-26T00:00:00Z")], "2026-10-25") == .away("Away all day"))
    }

    @Test func spansTheWeekFromLocalMidnightToLocalMidnight() throws {
        let days = ["2026-10-24", "2026-10-25", "2026-10-26"].map { PlanDay(date: PlanDate(iso: $0)!, plan: .open) }
        let range = try #require(CalendarDays.weekRange(days, calendar: london))
        #expect(range.start == (try Date("2026-10-23T23:00:00Z", strategy: .iso8601)))
        #expect(range.end == (try Date("2026-10-27T00:00:00Z", strategy: .iso8601)))
        #expect(CalendarDays.weekRange([], calendar: london) == nil)
    }

    @Test func onlyAwayAndOutAreBusyEvenings() {
        #expect(CalendarDays.Evening.away("x").isBusy)
        #expect(CalendarDays.Evening.out("x").isBusy)
        #expect(!CalendarDays.Evening.quick("x").isBusy)
        #expect(!CalendarDays.Evening.free.isBusy)
    }

    @Test func movingOnSkipsABusyEvening() {
        let days = (0..<4).map { PlanDay(date: PlanDate(iso: "2026-10-17")!.adding(days: $0), plan: .open) }
        let busy: Set<PlanDate> = [days[1].date]
        #expect(Week.nextOpenDay(days, from: days[0].date, skip: busy.contains) == days[2].date)
    }
}

/// What the phone's calendar counts as busy, and that it stays off without the usage key.
@MainActor struct CalendarReaderTests {
    @Test func onlyTimeAnEventTakesCountsAsBusy() {
        #expect(CalendarReader.counts(availability: .busy, isAllDay: false, calendar: .calDAV))
        #expect(CalendarReader.counts(availability: .tentative, isAllDay: false, calendar: .local))
        #expect(CalendarReader.counts(availability: .unavailable, isAllDay: true, calendar: .exchange))
        #expect(!CalendarReader.counts(availability: .free, isAllDay: false, calendar: .calDAV))
        #expect(CalendarReader.counts(availability: .notSupported, isAllDay: false, calendar: .subscription))
        #expect(!CalendarReader.counts(availability: .notSupported, isAllDay: true, calendar: .subscription))
        #expect(!CalendarReader.counts(availability: .busy, isAllDay: false, calendar: .birthday))
    }

    @Test func withoutTheUsageKeyItIsNeverOnAndAsksNothing() async {
        let defaults = UserDefaults(suiteName: "CalendarReaderTests")!
        defaults.set(true, forKey: "useCalendar")
        defer { defaults.removePersistentDomain(forName: "CalendarReaderTests") }
        let reader = CalendarReader(defaults: defaults, bundle: Bundle(for: BundleMarker.self))
        #expect(!reader.canAsk)
        #expect(!reader.isOn)
        await reader.setUseCalendar(true)
        #expect(!reader.isOn)
        #expect(reader.busy(from: .distantPast, to: .distantFuture).isEmpty)
    }
}

private final class BundleMarker {}
