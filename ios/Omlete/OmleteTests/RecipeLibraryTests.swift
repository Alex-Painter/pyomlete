import Foundation
import Testing
@testable import Omlete

/// The recipe side of `Library`: the grid's recipes, deleting one, adding one, and putting one on a list.
@MainActor struct RecipeLibraryTests {
    private typealias Call = ScriptedTransport.Call
    private let phone = Phone()
    private let addToWeek = Call(method: "POST", path: "/api/lists/list/recipes")

    private static let recipesJSON = """
        [{"id":"soup","title":"Soup","rating":5,"total_minutes":20,"source_name":null,"image_url":null},
         {"id":"curry","title":"Curry","rating":null,"total_minutes":35,"source_name":"example.com","image_url":null}]
        """
    private static let twoListsJSON = """
        [{"id":"list","name":"Week","created_at":null,"item_count":2,"checked_count":0,"recipes":[{"id":"curry","title":"Curry"}]},
         {"id":"other","name":"Party","created_at":null,"item_count":0,"checked_count":0,"recipes":[]}]
        """

    private func serverAnswers(_ override: @escaping (Call) -> ScriptedTransport.Reply? = { _ in nil }) {
        phone.serverAnswers { call in
            if let reply = override(call) { return reply }
            switch call.description {
            case "GET /api/lists/": return .status(200, Self.twoListsJSON)
            case "GET /api/recipes/": return .status(200, Self.recipesJSON)
            case "GET /api/units", "GET /api/settings/categories": return .status(200, "[]")
            case "POST /api/lists/": return .status(200, #"{"id":"new","name":"10th October","created_at":null}"#)
            default: return nil
            }
        }
    }

    private func calls(_ call: Call) -> Int {
        phone.transport.calls.count(where: { $0 == call })
    }

    @Test func addingToTheCurrentListSaysSoAndTheListAndItsHomeRowShowTheMeal() async {
        var added = false
        serverAnswers { [addToWeek] call in
            if call == addToWeek { added = true }
            guard added, call == Call(method: "GET", path: "/api/lists/list") else { return nil }
            return .status(200, #"{"id":"list","name":"Week","recipes":["curry","soup"],"items":[]}"#)
        }
        await phone.library.refresh()

        await phone.library.addMeal("soup", title: "Soup", to: .current)
        await phone.store.sync().value

        #expect(phone.undo.banner?.message == "Added Soup to Week")
        #expect(phone.transport.bodies[phone.transport.calls.firstIndex(of: addToWeek)!] as? [String: String] == ["recipe_id": "soup"])
        #expect(phone.store.replica.current?.recipes == ["curry", "soup"])
        #expect(phone.library.rows.first?.meals.map(\.title) == ["Curry", "Soup"])
        #expect(phone.library.cookShelf?.meals.map(\.title) == ["Curry", "Soup"])
    }

    @Test func undoingAnAddTakesTheMealBackOffTheList() async {
        serverAnswers()
        await phone.library.refresh()
        await phone.library.addMeal("soup", title: "Soup", to: .current)

        phone.undo.undoTapped()

        await eventually { calls(Call(method: "DELETE", path: "/api/lists/list/recipes/soup")) == 1 }
    }

    @Test func aMealAlreadyOnTheListIsSaidPlainlyWithNothingToUndo() async {
        serverAnswers { [addToWeek] in $0 == addToWeek ? .status(400, #"{"detail":"Recipe already on this list"}"#) : nil }
        await phone.library.refresh()

        await phone.library.addMeal("curry", title: "Curry", to: .current)

        #expect(phone.undo.banner?.message == "Curry is already on Week")
        #expect(phone.undo.banner?.canUndo == false)
    }

    @Test func anAddWithNoSignalSaysSo() async {
        serverAnswers()
        await phone.library.refresh()
        phone.serverIsUnreachable()

        await phone.library.addMeal("soup", title: "Soup", to: .current)

        #expect(phone.undo.banner?.message == "Couldn't reach Omlete. Soup wasn't added.")
    }

    @Test func theListAddedToBecomesTheCurrentOne() async {
        serverAnswers()
        await phone.library.refresh()
        #expect(phone.library.currentList?.name == "Week")

        await phone.library.addMeal("soup", title: "Soup", to: .list("other"))

        #expect(phone.undo.banner?.message == "Added Soup to Party")
        #expect(phone.library.currentList?.name == "Party")
        #expect(calls(Call(method: "POST", path: "/api/lists/other/recipes")) == 1)
    }

    @Test func withNoListsYetTheCurrentListIsANewOne() async {
        serverAnswers { $0.description == "GET /api/lists/" ? .status(200, "[]") : nil }
        await phone.library.refresh()

        await phone.library.addMeal("soup", title: "Soup", to: .current)

        #expect(phone.undo.banner?.message == "Added Soup to 10th October")
        #expect(calls(Call(method: "POST", path: "/api/lists/new/recipes")) == 1)
        #expect(phone.library.rows.map(\.name) == ["10th October"])
    }

    @Test func aNewListIsStartedWhenAskedForEvenWithListsToHand() async {
        serverAnswers()
        await phone.library.refresh()

        await phone.library.addMeal("soup", title: "Soup", to: .new)

        #expect(calls(Call(method: "POST", path: "/api/lists/")) == 1)
        #expect(calls(Call(method: "POST", path: "/api/lists/new/recipes")) == 1)
        #expect(calls(addToWeek) == 0)
    }

    @Test func deletingARecipeHidesItAndUndoBringsItBackWithNothingSent() async {
        serverAnswers()
        await phone.library.refresh()
        let before = phone.transport.calls.count

        phone.library.deleteRecipe("soup", title: "Soup")
        #expect(phone.library.recipes.map(\.title) == ["Curry"])
        #expect(phone.undo.banner?.message == "Deleted Soup")

        phone.undo.undoTapped()

        #expect(phone.library.recipes.map(\.title) == ["Soup", "Curry"])
        #expect(phone.transport.calls.count == before)
    }

    @Test func aSettledRecipeDeleteIsSentAndTheRecipeForgotten() async {
        serverAnswers()
        await phone.library.refresh()

        phone.library.deleteRecipe("soup", title: "Soup")
        phone.undo.commitNow()

        await eventually { phone.storage.index?.recipes.map(\.title) == ["Curry"] }
        #expect(phone.transport.calls.last == Call(method: "DELETE", path: "/api/recipes/soup"))
        #expect(phone.storage.index?.deletingRecipes.isEmpty == true)
    }

    @Test func aRecipeDeleteThatCannotBeSentIsRetriedAfterARelaunch() async {
        serverAnswers { $0.method == "DELETE" ? .unreachable : nil }
        await phone.library.refresh()
        phone.library.deleteRecipe("soup", title: "Soup")
        phone.undo.commitNow()
        await eventually { phone.transport.calls.last?.method == "DELETE" }

        phone.relaunch()
        #expect(phone.library.recipes.map(\.title) == ["Curry"])

        serverAnswers()
        phone.library.syncAll()

        await eventually { phone.storage.index?.deletingRecipes.isEmpty == true }
        #expect(phone.storage.index?.recipes.map(\.title) == ["Curry"])
    }

    @Test func aRecipeJustMadeIsFirstInTheLibraryAndStaysThereAfterARelaunch() async {
        serverAnswers { $0.path == "/api/recipes/generate/" ? .status(200, ExploreAPITests.traybakeJSON) : nil }
        await phone.library.refresh()

        let outcome = await phone.library.createRecipe(.describe("a traybake"))

        guard case .saved = outcome else { Issue.record("not saved"); return }
        #expect(phone.library.recipes.first == RecipeSummary(
            id: "traybake", title: "Traybake", totalMinutes: 45, rating: 5, sourceName: "example.com"))

        phone.serverIsUnreachable()
        phone.relaunch()
        #expect(phone.library.recipes.map(\.title) == ["Traybake", "Soup", "Curry"])
    }

    @Test func aRecipeThatCouldNotBeMadeLeavesTheLibraryAlone() async {
        serverAnswers { $0.method == "POST" ? .status(500) : nil }
        await phone.library.refresh()

        #expect(await phone.library.createRecipe(.describe("a traybake")) == .failed(.other))
        #expect(phone.library.recipes.map(\.title) == ["Soup", "Curry"])
    }
}

@MainActor struct RecipeIntakeTests {
    private typealias Call = ScriptedTransport.Call
    private let phone = Phone()
    private let importLink = Call(method: "POST", path: "/api/recipes/import-from-url/")

    private var intake: RecipeIntake { phone.intake }

    private func serverAnswers(_ reply: ScriptedTransport.Reply) {
        phone.serverAnswers { $0.method == "POST" ? reply : nil }
    }

    @Test func theButtonNamesWhatSubmittingWillDo() {
        #expect(intake.submitLabel == "Create recipe")
        #expect(!intake.canSubmit)

        intake.edit("leek and potato soup")
        #expect(intake.submitLabel == "Create recipe")
        #expect(intake.canSubmit)

        intake.edit("https://example.com/soup")
        #expect(intake.submitLabel == "Import recipe")

        let photo = RecipePhoto(id: UUID(), jpeg: Data())
        intake.attach(photo)
        #expect(intake.submitLabel == "Read 1 photo")
        intake.attach(RecipePhoto(id: UUID(), jpeg: Data()))
        #expect(intake.submitLabel == "Read 2 photos")

        intake.removePhoto(photo.id)
        #expect(intake.photos.count == 1)
    }

    @Test func aSavedRecipeEndsTheWorkClearsTheFieldAndJoinsTheLibrary() async {
        serverAnswers(.status(200, ExploreAPITests.traybakeJSON))
        phone.transport.holding = true
        intake.edit("https://example.com/traybake")

        intake.submit()
        #expect(intake.phase == .working(.link))
        #expect(!intake.canSubmit)

        intake.submit()
        intake.edit("something else")
        phone.transport.release()
        await eventually { !intake.isWorking }

        guard case .finished(.saved(let recipe)) = intake.phase else { Issue.record("not saved"); return }
        #expect(recipe.title == "Traybake")
        #expect(intake.text.isEmpty)
        #expect(phone.transport.calls == [importLink])
        #expect(phone.library.recipes.map(\.title) == ["Traybake"])
    }

    @Test func aLinkAlreadySavedKeepsWhatWasTypedAndEditingPutsTheAnswerAway() async {
        serverAnswers(.status(409, #"{"detail":{"message":"That page has already been imported.","recipe_id":"traybake"}}"#))
        intake.edit("https://example.com/traybake")

        intake.submit()
        await eventually { !intake.isWorking }

        #expect(intake.phase == .finished(.alreadySaved("traybake")))
        #expect(intake.text == "https://example.com/traybake")

        intake.edit("https://example.com/traybake-2")
        #expect(intake.phase == .editing)
    }

    @Test func aFailureKeepsTheInputForAnotherTry() async {
        serverAnswers(.status(502))
        intake.edit("https://example.com/down")

        intake.submit()
        await eventually { !intake.isWorking }

        #expect(intake.phase == .finished(.failed(.siteDidNotRespond)))
        #expect(intake.canSubmit)

        serverAnswers(.status(200, ExploreAPITests.traybakeJSON))
        intake.submit()
        await eventually { !intake.isWorking }
        #expect(phone.transport.calls == [importLink, importLink])
    }

    @Test func photosAreSentInsteadOfTheTextAndClearedOnceSaved() async {
        serverAnswers(.status(200, "[\(ExploreAPITests.traybakeJSON)]"))
        intake.edit("ignored")
        intake.attach(RecipePhoto(id: UUID(), jpeg: Data("page".utf8)))

        intake.submit()
        #expect(intake.phase == .working(.photos))
        await eventually { !intake.isWorking }

        #expect(phone.transport.calls == [Call(method: "POST", path: "/api/recipes/extract-from-images/")])
        #expect(intake.photos.isEmpty)
    }
}

/// The recipe page's view of a recipe, which shares its store with Cook.
@MainActor struct RecipePageTests {
    private typealias Call = ScriptedTransport.Call
    private let stove = Stove()
    private let exclude = Call(method: "PATCH", path: "/api/recipes/curry/ingredients/1/exclude")

    private var store: CookStore { stove.store }

    private var page: Recipe? {
        if case .ready(let recipe) = store.page { recipe } else { nil }
    }

    @Test func thePageLoadsTheRecipe() async {
        #expect(store.page == .loading)

        await store.load()

        #expect(page?.title == "Curry")
        #expect(page?.totalMinutes == 35)
    }

    @Test func lookingAtARecipeLeavesItsCookWhereItWas() async {
        await store.open()
        store.start()
        store.next()
        store.next()
        store.next()
        store.next()
        #expect(stove.session?.stage == .finished)

        await store.load()

        #expect(stove.session?.stage == .finished)
    }

    @Test func aRecipeNeverSeenAndUnreachableIsUnavailableAndADeletedOneIsGone() async {
        stove.serverIsUnreachable()
        await store.load()
        #expect(store.page == .unavailable)

        stove.serverAnswers { $0.method == "GET" ? .status(404) : nil }
        await store.load()
        #expect(store.page == .gone)
    }

    @Test func aRecipeSeenBeforeStillShowsWithNoSignal() async {
        await store.load()
        stove.relaunch()
        stove.serverIsUnreachable()

        await store.load()

        #expect(page?.title == "Curry")
    }

    @Test func aRecipeDeletedOnTheServerIsGoneFromItsPageButACookOfItCarriesOn() async {
        await store.open()
        store.start()
        stove.serverAnswers { $0.method == "GET" ? .status(404) : nil }

        await store.load()

        #expect(store.page == .gone)
        #expect(stove.session?.stage == .step(0))
    }

    @Test func midCookThePageShowsTheServersCopyAndTheCookKeepsItsOwn() async {
        await store.open()
        store.start()
        stove.serverAnswers { call in
            call.method == "GET" ? .status(200, Stove.recipeJSON.replacingOccurrences(of: #""title":"Curry""#, with: #""title":"Green curry""#)) : nil
        }

        await store.load()

        #expect(page?.title == "Green curry")
        #expect(stove.session?.recipe.title == "Curry")
    }

    @Test func takingAnIngredientOffListsShowsAtOnceAndTellsTheServer() async {
        await store.load()
        #expect(page?.ingredients.map(\.isOnList) == [true, true, true])

        store.setOnList(1, false)
        #expect(page?.ingredients.map(\.isOnList) == [true, false, true])

        await eventually { stove.transport.calls.last == exclude }
        #expect(stove.transport.bodies.last as? [String: Bool] == ["excluded": true])
        #expect(stove.storage.records[Stove.recipeID]?.session.recipe.ingredients[1].isOnList == false)

        store.setOnList(1, false)
        store.setOnList(7, false)
        #expect(stove.transport.calls.count(where: { $0.method == "PATCH" }) == 1)
    }

    @Test func aFlagTheServerCannotBeToldAboutFlipsBack() async {
        await store.load()
        stove.serverAnswers { $0.method == "PATCH" ? .unreachable : nil }

        store.setOnList(1, false)
        await eventually { stove.transport.calls.last == exclude }

        await eventually { page?.ingredients[1].isOnList == true }
    }

    @Test func flagsTappedQuicklyAreSentInTheOrderTapped() async {
        await store.load()
        stove.transport.holding = true

        store.setOnList(1, false)
        store.setOnList(1, true)
        stove.transport.release()

        await eventually { stove.transport.calls.count(where: { $0 == exclude }) == 2 }
        let sent = zip(stove.transport.calls, stove.transport.bodies).filter { $0.0 == exclude }.map { $0.1["excluded"] as? Bool }
        #expect(sent == [true, false])
        #expect(page?.ingredients[1].isOnList == true)
    }
}
