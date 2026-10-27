import Foundation
import Testing
@testable import Omlete

/// The web's `week.test.ts`, which is the spec.
struct WeekTests {
    private func date(_ iso: String) -> PlanDate { PlanDate(iso: iso)! }

    private func week(_ start: String, _ plans: [DayPlan] = []) -> [PlanDay] {
        (0..<7).map { PlanDay(date: date(start).adding(days: $0), plan: $0 < plans.count ? plans[$0] : .open) }
    }

    @Test func aDateReadsAndWritesAsTheServersString() throws {
        #expect(date("2026-10-20").iso == "2026-10-20")
        #expect(date("1970-01-01").daysSince1970 == 0)
        #expect(date("2024-02-29").adding(days: 1).iso == "2024-03-01")
        #expect(date("2026-12-31").adding(days: 1).iso == "2027-01-01")
        #expect(date("2026-10-17").days(to: date("2026-10-20")) == 3)
        #expect(date("2026-10-20").days(to: date("2026-10-17")) == -3)
        let decoded = try JSONDecoder().decode([PlanDate].self, from: Data(#"["2026-10-20"]"#.utf8))
        #expect(decoded == [date("2026-10-20")])
        #expect(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self) == #"["2026-10-20"]"#)
    }

    @Test(arguments: ["2026-02-30", "2026-13-01", "26-10-20", "2026-10-20T00:00:00", "", "2026-1-5"])
    func onlyADateThatExistsIsRead(text: String) {
        #expect(PlanDate(iso: text) == nil)
    }

    @Test func theWeekdayCountsFromMondayAsTheServerDoes() {
        // 2026-10-19 is a Monday, 2026-10-17 a Saturday.
        #expect(date("2026-10-19").weekday == 0)
        #expect(date("2026-10-17").weekday == 5)
        #expect(date("1969-12-31").weekday == 2)
    }

    @Test func weekStartGoesBackToTheMostRecentShopDayTodayIncluded() {
        #expect(Week.start(for: date("2026-10-20"), weekday: 5) == date("2026-10-17"))
        #expect(Week.start(for: date("2026-10-17"), weekday: 5) == date("2026-10-17"))
        #expect(Week.start(for: date("2026-10-16"), weekday: 5) == date("2026-10-10"))
        #expect(Week.start(for: date("2026-10-20"), weekday: 0) == date("2026-10-19"))
        #expect(Week.start(for: date("2027-01-01"), weekday: 5) == date("2026-12-26"))
    }

    @Test func todayFollowsThisDevicesMidnightNotUTCs() throws {
        var london = Calendar(identifier: .gregorian)
        london.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        // The night the clocks go back: 00:30 local is still 23:30 UTC the day before.
        let lateOnThe24th = try #require(london.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 23, minute: 59)))
        let earlyOnThe25th = try #require(london.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 0, minute: 30)))

        #expect(PlanDate.today(now: lateOnThe24th, calendar: london) == date("2026-10-24"))
        #expect(PlanDate.today(now: earlyOnThe25th, calendar: london) == date("2026-10-25"))
    }

    @Test func weekToPlanIsTheWeekUnderWayOrNextOnItsLastDayAndReusesItsList() {
        let lists = [
            ListSummary(id: "plain", name: "Plain", itemCount: 0, checkedCount: 0, meals: []),
            ListSummary(id: "last", name: "Last", itemCount: 0, checkedCount: 0, meals: [], weekStart: date("2026-10-10")),
            ListSummary(id: "this", name: "This", itemCount: 0, checkedCount: 0, meals: [], weekStart: date("2026-10-17")),
        ]

        #expect(Week.toPlan(today: date("2026-10-17"), weekday: 5, lists: []) == (date("2026-10-17"), nil))
        #expect(Week.toPlan(today: date("2026-10-22"), weekday: 5, lists: []) == (date("2026-10-17"), nil))
        #expect(Week.toPlan(today: date("2026-10-23"), weekday: 5, lists: []) == (date("2026-10-24"), nil))
        #expect(Week.toPlan(today: date("2026-10-20"), weekday: 5, lists: lists) == (date("2026-10-17"), "this"))
        #expect(Week.toPlan(today: date("2026-10-23"), weekday: 5, lists: lists).list == nil)
    }

    @Test func labelsNameTheDayAndMonth() {
        #expect(date("2026-10-17").shortLabel == "Sat 17 Oct")
        #expect(date("2026-10-17").longDate == "17 October")
        #expect(date("2026-10-20").dayLong == "Tuesday")
    }

    @Test func theDefaultDayIsTodayInsideTheWeekElseTheFirstEveningToPlan() {
        let days = week("2026-10-17", [.meal("a"), .out])

        #expect(Week.defaultDay(days, today: date("2026-10-20")) == date("2026-10-20"))
        #expect(Week.defaultDay(days, today: date("2026-10-10")) == date("2026-10-19"))
        #expect(Week.defaultDay(week("2026-10-17", Array(repeating: .out, count: 7)), today: date("2026-10-10")) == date("2026-10-17"))
        #expect(Week.defaultDay([], today: date("2026-10-10")) == nil)
    }

    @Test func theNextOpenDaySkipsPlannedAndOutDaysAndWrapsRoundTheWeek() {
        let days = week("2026-10-17", [.open, .meal("a"), .out, .open, .meal("b"), .meal("c"), .meal("d")])

        #expect(Week.nextOpenDay(days, from: date("2026-10-17")) == date("2026-10-20"))
        #expect(Week.nextOpenDay(days, from: date("2026-10-20")) == date("2026-10-17"))
    }

    @Test func theNextOpenDayStaysPutWhenEveryEveningIsDecided() {
        let days = week("2026-10-17", Array(repeating: .meal("x"), count: 7))

        #expect(Week.nextOpenDay(days, from: date("2026-10-19")) == date("2026-10-19"))
    }
}
