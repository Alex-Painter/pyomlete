import Foundation
import Testing
@testable import Omlete

private func date(_ iso: String) -> PlanDate { PlanDate(iso: iso)! }

/// Home's Plan a week: which week, open or make, and the shop day it counts from.
@MainActor struct PlanWeekTests {
    private typealias Call = ScriptedTransport.Call
    private let phone = Phone()
    private static let makeList = Call(method: "POST", path: "/api/lists/")
    private static let askWeekday = Call(method: "GET", path: "/api/settings/plan")
    /// A Tuesday. With the Saturday shop its week started on the 17th.
    private static let tuesday = date("2026-10-20")

    private static func listsJSON(weekStarts: [String?]) -> String {
        let rows = weekStarts.enumerated().map { place, start in
            let week = start.map { #""\#($0)""# } ?? "null"
            return #"{"id":"l\#(place)","name":"List \#(place)","item_count":0,"checked_count":0,"recipes":[],"week_start":\#(week)}"#
        }
        return "[\(rows.joined(separator: ","))]"
    }

    /// `weekday` nil is a server that cannot say.
    private func serverAnswers(weekStarts: [String?] = [], weekday: Int? = 5) {
        phone.serverAnswers { call in
            switch call {
            case Call(method: "GET", path: "/api/lists/"): .status(200, Self.listsJSON(weekStarts: weekStarts))
            case Self.askWeekday: weekday.map { .status(200, #"{"week_start_weekday":\#($0)}"#) } ?? .status(500)
            case Self.makeList:
                .answering { body in
                    let week = (body["week_start"] as? String).map { #""\#($0)""# } ?? "null"
                    return #"{"id":"new","name":"Week","created_at":null,"week_start":\#(week),"days":[]}"#
                }
            default: nil
            }
        }
    }

    private var made: [String?] {
        zip(phone.transport.calls, phone.transport.bodies)
            .filter { $0.0 == Self.makeList }
            .map { $0.1["week_start"] as? String }
    }

    @Test func opensThisWeeksListWhenThereIsOne() async throws {
        serverAnswers(weekStarts: ["2026-10-10", "2026-10-17"])
        await phone.library.refresh()

        let id = try await phone.library.planWeek(today: Self.tuesday)

        #expect(id == "l1")
        #expect(made.isEmpty)
    }

    @Test func makesTheWeekOnceAndASecondTapOpensIt() async throws {
        serverAnswers(weekStarts: ["2026-10-10", nil])
        await phone.library.refresh()

        let first = try await phone.library.planWeek(today: Self.tuesday)
        let second = try await phone.library.planWeek(today: Self.tuesday)

        #expect(first == "new")
        #expect(second == "new")
        #expect(made == ["2026-10-17"])
        #expect(phone.library.rows.first?.weekStart == date("2026-10-17"))
    }

    @Test func onTheLastDayOfAWeekItPlansTheNext() async throws {
        serverAnswers(weekStarts: ["2026-10-17"])
        await phone.library.refresh()

        _ = try await phone.library.planWeek(today: date("2026-10-23"))

        #expect(made == ["2026-10-24"])
    }

    @Test func countsFromTheServersShopDay() async throws {
        serverAnswers(weekday: 0)
        await phone.library.refresh()

        _ = try await phone.library.planWeek(today: Self.tuesday)

        #expect(made == ["2026-10-19"])
    }

    @Test func waitsToBeToldTheShopDayBeforeChoosingAWeek() async throws {
        serverAnswers(weekday: 0)

        _ = try await phone.library.planWeek(today: Self.tuesday)

        let calls = phone.transport.calls
        let asked = try #require(calls.firstIndex(of: Self.askWeekday))
        #expect(asked < calls.firstIndex(of: Self.makeList)!)
        #expect(made == ["2026-10-19"])
    }

    @Test func aShopDayTheServerCannotGiveIsSaturday() async throws {
        serverAnswers(weekday: nil)
        await phone.library.refresh()

        _ = try await phone.library.planWeek(today: Self.tuesday)

        #expect(made == ["2026-10-17"])
    }

    @Test func theShopDayIsRememberedWithNoSignal() async throws {
        serverAnswers(weekStarts: ["2026-10-19"], weekday: 0)
        await phone.library.refresh()
        phone.serverIsUnreachable()
        phone.relaunch()

        let id = try await phone.library.planWeek(today: Self.tuesday)

        #expect(id == "l0")
    }

    @Test func withTheListsNeverLoadedItNeedsSignal() async {
        phone.serverIsUnreachable()

        await #expect(throws: APIError.unreachable) { try await phone.library.planWeek(today: Self.tuesday) }
        #expect(!phone.transport.calls.contains(Self.makeList))
    }
}
