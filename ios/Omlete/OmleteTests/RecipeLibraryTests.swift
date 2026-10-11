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

    /// The meal picker shows recipes and nothing else the library loads.
    @Test func refreshingTheRecipesAloneAsksForNothingElse() async {
        serverAnswers()

        await phone.library.refreshRecipes()

        #expect(phone.transport.calls == [Call(method: "GET", path: "/api/recipes/")])
        #expect(phone.library.recipes.map(\.title) == ["Soup", "Curry"])
        #expect(phone.library.recipesLoaded)
    }

    @Test func aRecipesRefreshThatFailsKeepsTheRecipesAlreadyLoaded() async {
        serverAnswers()
        await phone.library.refresh()
        phone.serverIsUnreachable()

        await phone.library.refreshRecipes()

        #expect(phone.library.recipes.map(\.title) == ["Soup", "Curry"])
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

    @Test func beforeTheListsHaveLoadedAddingNeverStartsANewList() async {
        let phone = Phone(fetched: false)
        phone.serverAnswers { $0.description == "GET /api/lists/" ? .status(500) : nil }
        await phone.library.refresh()

        await phone.library.addMeal("soup", title: "Soup", to: .current)

        #expect(phone.undo.banner?.message == "Couldn't reach Omlete. Soup wasn't added.")
        #expect(!phone.transport.calls.contains(Call(method: "POST", path: "/api/lists/")))
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

    @Test func anEditedRecipeShowsItsNewTitleOnItsTileAndOnEveryListAtOnceAndAfterARelaunch() async {
        serverAnswers()
        await phone.library.refresh()
        var edited = Recipe.fixture()
        edited.title = "Green curry"
        edited.ingredients.removeLast()

        phone.library.adopt(edited)

        #expect(phone.library.recipes.map(\.title) == ["Soup", "Green curry"])
        #expect(phone.library.recipes[1].ingredientCount == 2)
        #expect(phone.library.recipes[1].sourceName == "example.com")
        #expect(phone.library.cookShelf?.meals.map(\.title) == ["Green curry"])
        #expect(phone.storage.index?.summaries[0].meals.map(\.title) == ["Green curry"])

        phone.relaunch()
        #expect(phone.library.recipes.map(\.title) == ["Soup", "Green curry"])
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
}

private extension RecipePage {
    /// The start an edit would be given from this page, for a page that is ready.
    var editable: EditStart? {
        if case .ready(let recipe) = self { .ready(recipe) } else { nil }
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

    private static let greenCurryJSON = Stove.recipeJSON
        .replacingOccurrences(of: #""title":"Curry""#, with: #""title":"Green curry""#)
        .replacingOccurrences(of: #""rating":null"#, with: #""rating":3"#)
    private let put = Call(method: "PUT", path: "/api/recipes/curry")
    private let greenCurry = RecipeEdit(title: "Green curry", steps: ["Simmer."], ingredients: [.init(name: "rice")])

    /// The server answers a PUT with the recipe as it now has it, which is not what was sent.
    private func serverSavesEdits() {
        stove.serverAnswers { [put] in $0 == put ? .status(200, Self.greenCurryJSON) : nil }
    }

    @Test func aSavedEditIsOnePutAndThePageShowsWhatTheServerAnswered() async throws {
        await store.load()
        serverSavesEdits()

        try await store.save(greenCurry)

        #expect(stove.transport.calls.count(where: { $0 == put }) == 1)
        #expect(stove.transport.bodies.last?["title"] as? String == "Green curry")
        #expect(page?.title == "Green curry")
        #expect(page?.steps.count == 4)
        #expect(page?.rating == 3)
        #expect(stove.reportedSaves.map(\.title) == ["Green curry"])
    }

    @Test func aCookNotYetStartedTakesTheEditAndStillHasItAfterARelaunchWithNoSignal() async throws {
        await store.open()
        serverSavesEdits()

        try await store.save(greenCurry)
        #expect(stove.session?.recipe.title == "Green curry")

        stove.relaunch()
        stove.serverIsUnreachable()
        await store.load()
        #expect(page?.title == "Green curry")
    }

    @Test func aCookUnderWayKeepsTheRecipeItStartedWithWhileThePageShowsTheEdit() async throws {
        await store.open()
        store.start()
        store.next()
        serverSavesEdits()

        try await store.save(greenCurry)

        #expect(page?.title == "Green curry")
        #expect(stove.session?.recipe.title == "Curry")
        #expect(stove.session?.stage == .step(1))
    }

    @Test(arguments: [ScriptedTransport.Reply.unreachable, .status(500), .status(404), .status(422)])
    func anEditThatCannotBeSavedThrowsAndChangesNothing(reply: ScriptedTransport.Reply) async {
        await store.load()
        stove.serverAnswers { [put] in $0 == put ? reply : nil }

        await #expect(throws: APIError.self) { try await store.save(greenCurry) }

        #expect(page?.title == "Curry")
        #expect(stove.session?.recipe.title == "Curry")
        #expect(stove.reportedSaves.isEmpty)
    }

    @Test func anEditWaitsForAnOnListChangeStillOnItsWayBecauseThatNamesItsIngredientByPosition() async throws {
        await store.load()
        serverSavesEdits()
        stove.transport.holding = true

        store.setOnList(1, false)
        async let saving: Void = store.save(greenCurry)
        await eventually { stove.transport.calls.last == exclude }
        #expect(!stove.transport.calls.contains(put))
        stove.transport.release()
        try await saving

        #expect(stove.transport.calls.suffix(2) == [exclude, put])
    }

    private func excludedFlags(in body: [String: Any]?) -> [Bool?] {
        (body?["ingredients"] as? [[String: Any]] ?? []).map { $0["excluded_from_list"] as? Bool }
    }

    /// The draft copied "off lists" while that change was still on its way. It failed, so the save must not send it.
    @Test func anEditMadeWhileAnOnListChangeWasFailingSavesTheFlagAsItEndedUp() async throws {
        await store.load()
        stove.serverAnswers { [put, exclude] call in
            if call == exclude { return .unreachable }
            return call == put ? .status(200, Self.greenCurryJSON) : nil
        }
        stove.transport.holding = true
        store.setOnList(1, false)
        guard let shown = page else { return }
        #expect(shown.ingredients[1].isOnList == false)
        guard case .save(let edit) = RecipeDraft(shown).outcome else { return }

        async let saving: Void = store.save(edit)
        await eventually { stove.transport.calls.last == exclude }
        stove.transport.release()
        try await saving

        #expect(excludedFlags(in: stove.transport.bodies.last) == [false, false, false])
    }

    @Test func aFlagChangedAfterTheDraftWasMadeIsKeptByTheSave() async throws {
        await store.load()
        serverSavesEdits()
        guard let shown = page, case .save(let edit) = RecipeDraft(shown).outcome else { return }

        store.setOnList(2, false)
        try await store.save(edit)

        #expect(excludedFlags(in: stove.transport.bodies.last) == [false, false, true])
    }

    @Test func afterAnEditReordersACooksIngredientsAFlagIsNotSetOnTheWrongOne() async throws {
        await store.open()
        store.start()
        let reordered = Stove.recipeJSON.replacingOccurrences(
            of: #"{"name":"onions","amount":2,"unit":"whole","note":"finely chopped","category":"Produce","excluded_from_list":false},"#,
            with: "")
        stove.serverAnswers { [put] in $0 == put ? .status(200, reordered) : nil }
        try await store.save(greenCurry)
        #expect(page?.ingredients.first?.name == "rice")

        store.setOnList(0, false)

        #expect(page?.ingredients[0].isOnList == false)
        #expect(stove.session?.recipe.ingredients.map(\.isOnList) == [true, true, true])
    }

    @Test func anEditStartsOnlyFromACopyTheServerGaveThisLaunch() async {
        await store.load()
        #expect(store.hasServerCopy)

        stove.relaunch()
        stove.serverIsUnreachable()
        await stove.store.load()
        #expect(stove.store.page != .loading)
        #expect(!stove.store.hasServerCopy)
        #expect(await stove.store.recipeToEdit() == .unavailable(.unreachable))
    }

    @Test func anEditFromACopySavedOnThePhoneAsksTheServerFirstAndStartsFromItsAnswer() async {
        await store.load()
        stove.relaunch()
        stove.serverIsUnreachable()
        await stove.store.load()
        stove.serverAnswers { $0.method == "GET" ? .status(200, Self.greenCurryJSON) : nil }

        guard case .ready(let recipe) = await stove.store.recipeToEdit() else {
            Issue.record("the edit did not start")
            return
        }
        #expect(recipe.title == "Green curry")
        #expect(stove.store.hasServerCopy)
    }

    @Test func anEditFromACopyTheServerAlreadyGaveAsksNothingMore() async {
        await store.load()
        let asked = stove.transport.calls.count

        #expect(await store.recipeToEdit() == store.page.editable)
        #expect(stove.transport.calls.count == asked)
    }

    @Test func anEditDoesNotStartForARecipeDeletedOnTheServerOrOneTheServerFailsToGive() async {
        await store.load()
        stove.relaunch()
        stove.serverAnswers { $0.method == "GET" ? .status(500) : nil }
        #expect(await stove.store.recipeToEdit() == .unavailable(.serverFault(500)))

        stove.serverAnswers { $0.method == "GET" ? .status(404) : nil }
        #expect(await stove.store.recipeToEdit() == .gone)
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

    @Test func changingAFlagLeavesARatingJustGivenAlone() async {
        await store.load()
        store.rate(4)
        await eventually { store.rating.status == .sent }

        store.setOnList(1, false)

        #expect(store.rating.stars == 4)
        #expect(stove.storage.records[Stove.recipeID]?.session.recipe.rating == 4)
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
