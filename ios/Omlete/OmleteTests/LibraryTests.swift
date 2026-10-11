import Foundation
import Testing
@testable import Omlete

@MainActor struct LibraryTests {
    private typealias Call = ScriptedTransport.Call
    private let phone = Phone()

    private static let listsJSON = """
        [{"id":"list","name":"Week","created_at":"2026-10-10T09:00:00","item_count":2,"checked_count":0,
          "recipes":[{"id":"curry","title":"Curry"}]},
         {"id":"other","name":"Party","created_at":null,"item_count":5,"checked_count":1,"recipes":[]}]
        """

    private static let twoMealListsJSON = """
        [{"id":"other","name":"Party","created_at":null,"item_count":5,"checked_count":1,
          "recipes":[{"id":"tacos","title":"Tacos"}]},
         {"id":"list","name":"Week","created_at":null,"item_count":2,"checked_count":0,
          "recipes":[{"id":"curry","title":"Curry"}]}]
        """

    private func serverAnswers(_ override: @escaping (Call) -> ScriptedTransport.Reply? = { _ in nil }) {
        phone.serverAnswers { call in
            if let reply = override(call) { return reply }
            switch call.description {
            case "GET /api/lists/": return .status(200, Self.listsJSON)
            case "GET /api/settings/categories": return .status(200, #"[{"name":"Dairy","order":1},{"name":"Bakery","order":0}]"#)
            case "GET /api/recipes/": return .status(200, #"[{"id":"curry","title":"Thai curry","image_url":"https://img.test/c.jpg","rating":null,"total_minutes":35}]"#)
            case "GET /api/units": return .status(200, #"["g","tin"]"#)
            case "POST /api/lists/": return .status(200, #"{"id":"new","name":"10th October","created_at":"2026-10-10T09:00:00"}"#)
            case "POST /api/lists/list/duplicate": return .status(200, #"{"id":"copy","name":"10th October","created_at":null}"#)
            default: return nil
            }
        }
    }

    @Test func refreshLoadsRowsAislesRecipesAndUnitsAndSavesThem() async {
        serverAnswers()

        await phone.library.refresh()

        #expect(phone.library.rows.map(\.name) == ["Week", "Party"])
        #expect(phone.library.aisleOrder == ["Bakery", "Dairy"])
        #expect(phone.library.units == ["g", "tin"])
        #expect(phone.library.meal("curry") == RecipeSummary(
            id: "curry", title: "Thai curry", imageURL: URL(string: "https://img.test/c.jpg"), totalMinutes: 35))

        phone.serverIsUnreachable()
        phone.relaunch()

        #expect(phone.library.rows.map(\.name) == ["Week", "Party"])
        #expect(phone.library.aisleOrder == ["Bakery", "Dairy"])
    }

    @Test func aRefreshMadeDuringAnotherJoinsIt() async {
        serverAnswers()

        async let first: Void = phone.library.refresh()
        async let second: Void = phone.library.refresh()
        _ = await (first, second)

        #expect(phone.transport.calls.count(where: { $0.path == "/api/lists/" }) == 1)
        #expect(phone.library.rows.count == 2)
    }

    @Test func aRowShowsUnsentChangesFromItsList() async {
        serverAnswers { $0.path.hasPrefix("/api/lists/list") ? .unreachable : nil }
        await phone.library.refresh()

        phone.store.setChecked("bread", true)
        phone.store.rename("Weekend")
        phone.library.list("other").rename("Birthday")

        #expect(phone.library.rows.map(\.name) == ["Weekend", "Birthday"])
        #expect(phone.library.rows[0].checkedCount == 1)
        #expect(phone.library.rows[1].itemCount == 5)
    }

    @Test func aFailedLoadWithNothingSavedIsReported() async {
        phone.serverIsUnreachable()
        #expect(!phone.library.hasLoaded)

        await phone.library.refresh()

        #expect(phone.library.loadFailure == .unreachable)
        #expect(phone.library.rows.isEmpty)

        phone.relaunch()
        #expect(!phone.library.hasLoaded)
    }

    @Test func theShelfOffersTheMealsOfTheFirstListUntilOneIsOpened() async {
        serverAnswers { $0.description == "GET /api/lists/" ? .status(200, Self.twoMealListsJSON) : nil }
        await phone.library.refresh()

        #expect(phone.library.cookShelf?.listName == "Party")
        #expect(phone.library.cookShelf?.meals.map(\.title) == ["Tacos"])

        phone.library.markCurrent("list")

        #expect(phone.library.cookShelf == CookShelf(listID: "list", listName: "Week", meals: [
            RecipeSummary(id: "curry", title: "Thai curry", imageURL: URL(string: "https://img.test/c.jpg"), totalMinutes: 35),
        ]))
    }

    @Test func theListLastOpenedIsRememberedAcrossARelaunch() async {
        serverAnswers { $0.description == "GET /api/lists/" ? .status(200, Self.twoMealListsJSON) : nil }
        await phone.library.refresh()
        phone.library.markCurrent("list")

        phone.relaunch()

        #expect(phone.library.cookShelf?.listID == "list")
    }

    @Test func aRememberedListThatIsGoneFallsBackToTheFirstRow() async {
        serverAnswers { $0.description == "GET /api/lists/" ? .status(200, Self.twoMealListsJSON) : nil }
        await phone.library.refresh()
        phone.library.markCurrent("list")

        phone.library.delete("list")

        #expect(phone.library.cookShelf?.listName == "Party")
    }

    @Test func aListWithNoMealsHasNoShelf() async {
        serverAnswers()
        await phone.library.refresh()
        #expect(phone.library.cookShelf?.listName == "Week")

        phone.library.markCurrent("other")
        #expect(phone.library.cookShelf == nil)

        phone.library.markCurrent("list")
        phone.store.removeMeal("curry", title: "Thai curry")
        #expect(phone.library.cookShelf == nil)
    }

    @Test func aNewListAppearsFirstUnderTheServersName() async throws {
        serverAnswers()
        await phone.library.refresh()

        let id = try await phone.library.newList()

        #expect(id == "new")
        #expect(phone.library.rows.map(\.name) == ["10th October", "Week", "Party"])
    }

    @Test func aDuplicateStartsUncheckedWithTheSameItemsAndMeals() async throws {
        serverAnswers()
        await phone.library.refresh()

        let id = try await phone.library.duplicate("list")

        let copy = try #require(phone.library.rows.first)
        #expect(id == "copy")
        #expect(copy.itemCount == 2)
        #expect(copy.checkedCount == 0)
        #expect(copy.meals.map(\.title) == ["Thai curry"])
    }

    @Test func newListNeedsSignal() async {
        phone.serverIsUnreachable()

        await #expect(throws: APIError.unreachable) { try await phone.library.newList() }
    }

    @Test func deletingAListHidesItAndUndoBringsItBackWithNothingSent() async {
        serverAnswers()
        await phone.library.refresh()
        let before = phone.transport.calls.count

        phone.library.delete("other")
        #expect(phone.library.rows.map(\.name) == ["Week"])
        #expect(phone.undo.banner?.message == "Deleted Party")

        phone.undo.undoTapped()

        #expect(phone.library.rows.map(\.name) == ["Week", "Party"])
        #expect(phone.transport.calls.count == before)
    }

    @Test func aSettledDeleteIsSentAndTheListForgotten() async {
        serverAnswers()
        await phone.library.refresh()

        phone.library.delete("list")
        phone.undo.commitNow()

        await eventually { phone.storage.replicas[Phone.listID] == nil }
        #expect(phone.transport.calls.last == Call(method: "DELETE", path: "/api/lists/list"))
        #expect(phone.storage.index?.summaries.map(\.name) == ["Party"])
        #expect(phone.storage.index?.deletingLists.isEmpty == true)
    }

    @Test func aDeleteThatCannotBeSentIsRetriedAfterARelaunch() async {
        serverAnswers { $0.method == "DELETE" ? .unreachable : nil }
        await phone.library.refresh()
        phone.library.delete("other")
        phone.undo.commitNow()
        await eventually { phone.transport.calls.last?.method == "DELETE" }

        phone.relaunch()
        #expect(phone.library.rows.map(\.name) == ["Week"])

        serverAnswers()
        phone.library.syncAll()

        await eventually { phone.storage.index?.deletingLists.isEmpty == true }
        #expect(phone.storage.index?.summaries.map(\.name) == ["Week"])
    }
}

@MainActor struct UndoCenterTests {
    @Test func undoRunsOnlyUndo() {
        let undo = UndoCenter()
        var log: [String] = []
        undo.offer("Removed", undo: { log.append("undo") }, commit: { log.append("commit") })

        undo.undoTapped()
        undo.commitNow()

        #expect(log == ["undo"])
        #expect(undo.banner == nil)
    }

    @Test func aNewOfferCommitsTheOneBeforeIt() {
        let undo = UndoCenter()
        var log: [String] = []
        undo.offer("First", undo: {}, commit: { log.append("first") })

        undo.offer("Second", undo: {}, commit: { log.append("second") })

        #expect(log == ["first"])
        #expect(undo.banner?.message == "Second")
    }

    @Test func theBannerCommitsWhenItsTimeIsUp() async {
        let undo = UndoCenter(duration: .milliseconds(20))
        var log: [String] = []
        undo.offer("Removed", undo: { log.append("undo") }, commit: { log.append("commit") })

        await eventually { undo.banner == nil }
        undo.undoTapped()

        #expect(log == ["commit"])
    }

    @Test func newsWaitsBehindAnUndoAndIsSaidInOrderOnceItHasSettled() async {
        let undo = UndoCenter(duration: .milliseconds(20))
        undo.offer("Removed", undo: {})

        undo.inform("First")
        undo.inform("Second")
        #expect(undo.banner?.message == "Removed")

        undo.undoTapped()
        #expect(undo.banner?.message == "First")
        await eventually { undo.banner?.message == "Second" }
        await eventually { undo.banner == nil }
    }

    /// Putting a meal back inside its Undo window settles that banner and offers "Added" in the same turn.
    @Test func newsCutShortByAnOfferIsSaidAgainAfterIt() async {
        let undo = UndoCenter(duration: .milliseconds(20))
        undo.offer("Removed", undo: {})
        undo.inform("Couldn't save")

        undo.undoTapped()
        undo.offer("Added", undo: {})

        #expect(undo.banner?.message == "Added")
        await eventually { undo.banner?.message == "Couldn't save" }
    }

    @Test func aMessageWithNothingToUndoGivesWayToNewsAtOnce() {
        let undo = UndoCenter()
        undo.offer("Saving")

        undo.inform("Couldn't save")

        #expect(undo.banner?.message == "Couldn't save")
    }

    @Test func newsThatComesWhileTheAppIsAwayIsSaidWhenItIsBack() {
        let undo = UndoCenter()
        undo.appLeftFront()

        undo.inform("Couldn't save")
        #expect(undo.banner == nil)

        undo.appCameToFront()
        #expect(undo.banner?.message == "Couldn't save")
    }

    @Test func leavingTheAppCommitsWhatCouldBeUndoneAndKeepsTheNewsBehindItForTheReturn() {
        let undo = UndoCenter()
        var log: [String] = []
        undo.offer("Removed", undo: { log.append("undo") }, commit: { log.append("commit") })
        undo.inform("Couldn't save")

        undo.appLeftFront()
        #expect(log == ["commit"])
        #expect(undo.banner == nil)

        undo.appCameToFront()
        #expect(undo.banner?.message == "Couldn't save")
    }

    @Test func newsStillUpWhenTheAppLeavesIsSaidAgainOnTheReturn() {
        let undo = UndoCenter()
        undo.inform("Couldn't save")
        #expect(undo.banner?.message == "Couldn't save")

        undo.appLeftFront()
        #expect(undo.banner == nil)

        undo.appCameToFront()
        #expect(undo.banner?.message == "Couldn't save")
    }
}

struct APIErrorTests {
    @Test(arguments: [
        (200, nil), (204, nil),
        (500, APIError.serverFault(500)), (503, .serverFault(503)), (408, .serverFault(408)), (429, .serverFault(429)),
        (400, .rejected(400)), (404, .rejected(404)), (422, .rejected(422)),
    ] as [(Int, APIError?)])
    func classifiesAStatus(status: Int, expected: APIError?) {
        #expect(APIError(status: status) == expected)
    }

    @Test func onlyFailuresThatMightPassLaterAreRetryable() {
        #expect(APIError.unreachable.isRetryable)
        #expect(APIError.serverFault(429).isRetryable)
        #expect(!APIError.rejected(404).isRetryable)
        #expect(!APIError.undecodable.isRetryable)
    }
}
