import Foundation
import Testing
@testable import Omlete

@MainActor struct ChefWeekTests {
    private typealias Call = ScriptedTransport.Call

    /// What the server holds, which a test changes to play the new ideas landing.
    @MainActor private final class Server {
        var waiting: String? = ChefWeekTests.planJSON
        /// The made list's meals, as `GET /api/lists/week` answers them.
        var meals = ["curry", "dal", "stew"]
        var detail: String {
            let recipes = meals.map { "\"\($0)\"" }.joined(separator: ",")
            return #"{"id":"week","name":"Week of 24 Oct","recipes":[\#(recipes)],"items":[]}"#
        }
    }

    /// Out of day order, as nothing promises the server sends it in order.
    static let planJSON = """
        {"id":"plan","week_of":"2026-10-24","note":"A cosy week.","status":"new","list_id":null,"meals":[
        {"day":"2026-10-26","title":"Miso salmon","reason":"Something new to try.","recipe_id":null,"is_new":true,
         "image_url":null,"source_url":"https://example.com/miso"},
        {"day":"2026-10-24","title":"Curry","reason":"You rated it 5 stars.","recipe_id":"curry","is_new":false,
         "image_url":"https://example.com/curry.jpg","source_url":null},
        {"day":"2026-10-25","title":"Dal","reason":"Quick for a Sunday.","recipe_id":"dal","is_new":false,
         "image_url":null,"source_url":null},
        {"day":"2026-10-27","title":"Stew","reason":"Not had in a month.","recipe_id":"stew","is_new":false,
         "image_url":null,"source_url":null},
        {"day":"2026-10-29","title":"Bao","reason":"A Friday treat.","recipe_id":null,"is_new":true,
         "image_url":null,"source_url":"https://example.com/bao"}]}
        """

    private let phone = Phone()
    private let server = Server()
    private let make = Call(method: "POST", path: "/api/weeks/plan/make")
    private let undoMake = Call(method: "POST", path: "/api/chef/actions/act1/undo")
    private let skip = Call(method: "POST", path: "/api/weeks/plan/skip")
    private let getWeek = Call(method: "GET", path: "/api/weeks/current")
    private let getMadeList = Call(method: "GET", path: "/api/lists/week")
    private let getLists = Call(method: "GET", path: "/api/lists/")

    private var week: ChefWeek { phone.chef.week }

    init() {
        serverAnswers()
    }

    private func serverAnswers(_ override: @escaping (Call) -> ScriptedTransport.Reply? = { _ in nil }) {
        phone.serverAnswers { [server] call in
            if let reply = override(call) { return reply }
            switch call.description {
            case "GET /api/weeks/current": return .status(200, server.waiting ?? "null")
            case "POST /api/weeks/plan": return .status(200, Self.planJSON)
            case "POST /api/weeks/plan/make":
                return .status(200, #"{"list_id":"week","name":"Week of 24 Oct","undo":"act1"}"#)
            case "GET /api/lists/week": return .status(200, server.detail)
            case "GET /api/lists/": return .status(200, Phone.listsJSON)
            case "GET /api/recipes/", "GET /api/units", "GET /api/settings/categories": return .status(200, "[]")
            default: return nil
            }
        }
    }

    private func calls(_ call: Call) -> Int {
        phone.transport.calls.count(where: { $0 == call })
    }

    @Test func aWaitingPlanIsReadInDayOrderWithItsNewIdeasMarked() async {
        await week.load()

        let plan = try! #require(week.shown)
        #expect(plan.id == "plan")
        #expect(plan.weekOf == PlanDate(year: 2026, month: 10, day: 24))
        #expect(plan.note == "A cosy week.")
        #expect(plan.meals.map(\.title) == ["Curry", "Dal", "Miso salmon", "Stew", "Bao"])
        #expect(plan.meals.map(\.isNew) == [false, false, true, false, true])
        #expect(plan.meals[0].recipe == "curry")
        #expect(plan.meals[0].imageURL == URL(string: "https://example.com/curry.jpg"))
        #expect(plan.meals[0].reason == "You rated it 5 stars.")
    }

    @Test func noPlanWaitingShowsNoCardAndAFailedLoadKeepsTheCardShown() async {
        server.waiting = nil
        await week.load()
        #expect(week.shown == nil)

        server.waiting = Self.planJSON
        await week.load()
        phone.serverIsUnreachable()
        await week.load()
        #expect(week.shown?.id == "plan")
    }

    @Test func makeTheListHidesTheCardAndOffersUndoAndOpenWithTheListOnHome() async {
        await week.load()
        var opened: [ListID] = []

        week.make { opened.append($0) }
        await eventually { phone.undo.banner != nil }

        #expect(calls(make) == 1)
        #expect(week.shown == nil)
        let banner = try! #require(phone.undo.banner)
        #expect(banner.message == "Made Week of 24 Oct. New ideas join it as they're ready.")
        #expect(banner.canUndo)
        #expect(banner.action == "Open")
        // Nothing navigates by itself.
        #expect(opened.isEmpty)
        await eventually { calls(getLists) > 0 }
    }

    @Test func undoAsksChefToPutTheListBackAndTheCardReturns() async {
        await week.load()
        week.make { _ in }
        await eventually { phone.undo.banner?.canUndo == true }

        phone.undo.undoTapped()

        await eventually { week.shown?.id == "plan" }
        #expect(calls(undoMake) == 1)
        #expect(phone.undo.banner == nil)
    }

    @Test func anUndoRefusedBecauseTheListChangedSaysTheListWasKept() async {
        serverAnswers { [undoMake] call in call == undoMake ? .status(409, #"{"detail":"changed"}"#) : nil }
        await week.load()
        week.make { _ in }
        await eventually { phone.undo.banner?.canUndo == true }

        phone.undo.undoTapped()

        await eventually { phone.undo.banner?.message == "That list has changed since, so it was kept." }
    }

    @Test func openKeepsTheListAndGoesToIt() async {
        await week.load()
        var opened: [ListID] = []
        week.make { opened.append($0) }
        await eventually { phone.undo.banner?.action == "Open" }

        phone.undo.actionTapped()

        #expect(opened == ["week"])
        #expect(phone.undo.banner == nil)
        #expect(calls(undoMake) == 0)
    }

    @Test func aMakeThatFailsSaysSoAndKeepsTheCard() async {
        serverAnswers { [make] call in call == make ? .status(500) : nil }
        await week.load()

        week.make { _ in }

        await eventually { phone.undo.banner?.message == "Couldn't make the list. Try again." }
        #expect(week.shown?.id == "plan")
        #expect(!week.isMaking)
    }

    @Test func theMadeListIsRefreshedUntilItsNewIdeasHaveLandedThenLeftAlone() async {
        await week.load()
        week.make { _ in }
        await eventually { phone.ticker.isWaiting }

        phone.ticker.tick()
        await eventually { phone.ticker.isWaiting && calls(getMadeList) == 2 }

        // Both ideas have saved and landed on their evenings.
        server.meals += ["miso", "bao"]
        phone.ticker.tick()
        await eventually { phone.library.list("week").replica.current?.recipes.count == 5 }
        await eventually { !phone.ticker.isWaiting }
        let fetched = calls(getMadeList)

        phone.ticker.tick()
        #expect(calls(getMadeList) == fetched)
    }

    @Test func theMadeListIsLeftAloneOnceTheSavesWouldHaveEnded() async {
        await week.load()
        week.make { _ in }
        await eventually { phone.ticker.isWaiting }

        phone.now += Chef.giveUpAfter
        phone.ticker.tick()

        await eventually { !phone.ticker.isWaiting }
        #expect(calls(getMadeList) == 1)
    }

    @Test func notThisWeekHidesTheCardAndUndoBringsItBackWithNothingSent() async {
        await week.load()

        week.skip()
        #expect(week.shown == nil)
        #expect(phone.undo.banner?.message == "Skipped this week")

        phone.undo.undoTapped()
        #expect(week.shown?.id == "plan")
        #expect(calls(skip) == 0)
    }

    @Test func aSettledNotThisWeekTellsTheServerAndALoadMeanwhileKeepsItHidden() async {
        await week.load()

        week.skip()
        await week.load()
        #expect(week.shown == nil)
        phone.undo.commitNow()

        await eventually { calls(skip) == 1 }
        server.waiting = nil
        await week.load()
        #expect(week.shown == nil)
    }

    @Test func planMyWeekIsOwnedByTheAppSoItFinishesWithNoScreenWaitingAndAsksOnce() async {
        server.waiting = nil
        phone.transport.holding = true

        week.planMyWeek()
        week.planMyWeek()
        #expect(week.isPlanning)
        await eventually { calls(Call(method: "POST", path: "/api/weeks/plan")) == 1 }
        let request = try! #require(phone.transport.requests.last { $0.url?.path() == "/api/weeks/plan" })
        #expect(request.timeoutInterval == APIClient.slowTimeout)

        phone.transport.release()

        await eventually { !week.isPlanning }
        #expect(week.shown?.id == "plan")
        #expect(calls(Call(method: "POST", path: "/api/weeks/plan")) == 1)
    }

    @Test func planMyWeekThatFailsSaysSoAndLooksAgainInCaseTheServerFinished() async {
        server.waiting = nil
        serverAnswers { call in call.description == "POST /api/weeks/plan" ? .status(500) : nil }

        week.planMyWeek()

        await eventually { !week.isPlanning }
        #expect(phone.undo.banner?.message == "Chef couldn't plan a week right now. Try again in a bit.")
        #expect(calls(getWeek) == 1)
        #expect(week.shown == nil)
    }
}
