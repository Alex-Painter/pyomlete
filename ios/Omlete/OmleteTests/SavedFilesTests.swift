import Foundation
import Testing
@testable import Omlete

/// What the first build wrote to the phone has to keep loading. A cook that
/// fails to decode is deleted with its timers, and an index that fails takes
/// the unsent list deletes and the current list with it.
struct SavedFilesTests {
    /// A cook file as written by the build before recipes had sources, pictures or shopping-list flags.
    private static let cookFromTheFirstBuild = """
        {"session":{"stage":{"step":{"_0":1}},"servings":{"value":2,"base":2},"recipe":{"baseServings":2,\
        "title":"Verify Fixture Shakshuka","id":"6acab1ae79419b02abd05ef4","steps":["Soften the onion and pepper in olive oil.",\
        "Add tomatoes and spices; simmer 10 minutes.","Make wells, crack in the eggs, cover until set."],\
        "ingredients":[{"name":"eggs","amount":4,"unit":"whole"},{"name":"chopped tomatoes","amount":400,"unit":"grams"},\
        {"note":"finely chopped","name":"onion","amount":1,"unit":"whole"},{"name":"red pepper","amount":1,"unit":"whole"}],\
        "rating":4},"touchedAt":813361764.575945,"timers":[{"stepIndex":1,"id":"D1091720-9B9C-4F34-9443-C1B6B4B37D18",\
        "label":"10 minutes","rung":false,"endsAt":813362121.673081}]},"unsentRating":5}
        """

    /// An index file as written by the build before recipes could be deleted.
    private static let indexFromTheFirstBuild = """
        {"currentList":"6acab1afc5726b9df81a350b","aisleOrder":["Fresh Produce","Other"],\
        "recipes":[{"title":"Verify Fixture Soft Egg","id":"6acab1ae4517e51ae7d193e9"},\
        {"title":"Verify Fixture Shakshuka","id":"6acab1ae79419b02abd05ef4","totalMinutes":25}],"units":["grams","whole"],\
        "summaries":[{"meals":[{"title":"Verify Fixture Soft Egg","id":"6acab1ae4517e51ae7d193e9"}],\
        "name":"Verify Fixture List","id":"6acab1afc5726b9df81a350b","checkedCount":1,"itemCount":6}],\
        "deletingLists":["6acab1afc5726b9df81a350c"]}
        """

    /// An index file as written by the build before recipes carried an ingredient count.
    private static let indexFromBeforeAddMeals = """
        {"currentList":"6ae9a8b03b1d1a5f0c2e7711","aisleOrder":["Fresh Produce","Other"],"units":["grams"],\
        "recipes":[{"id":"6ae9a8af3b1d1a5f0c2e7701","title":"Verify Fixture Traybake","totalMinutes":45,"rating":5,\
        "sourceName":"example.com","imageURL":"https://img.test/t.jpg"},\
        {"id":"6ae9a8af3b1d1a5f0c2e7702","title":"Verify Fixture Soft Egg"}],\
        "summaries":[{"meals":[],"name":"Verify Fixture List","id":"6ae9a8b03b1d1a5f0c2e7711","checkedCount":0,"itemCount":2}],\
        "deletingLists":[],"deletingRecipes":["6ae9a8af3b1d1a5f0c2e7703"]}
        """

    /// A list file as written by the build before lists had weeks.
    private static let listFromBeforeWeeks = """
        {"id":"list","base":{"id":"list","name":"Week","recipes":["curry"],"items":[{"id":"rice","name":"rice",\
        "amount":200,"unit":"g","category":"Pantry","checked":false,"sources":[{"recipeID":"curry","amount":200}]}]},\
        "pending":[{"id":"op1","op":{"rename":{"_0":"Weekend"}},"held":false}]}
        """

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }

    @Test func aCookSavedByTheFirstBuildOpensWhereItWasLeft() throws {
        let record = try JSONDecoder().decode(CookRecord.self, from: Data(Self.cookFromTheFirstBuild.utf8))

        #expect(record.unsentRating == 5)
        #expect(record.session.stage == .step(1))
        #expect(record.session.timers.map(\.label) == ["10 minutes"])
        #expect(record.session.recipe.title == "Verify Fixture Shakshuka")
        #expect(record.session.recipe.ingredients.map(\.name) == ["eggs", "chopped tomatoes", "onion", "red pepper"])
        #expect(record.session.recipe.ingredients.map(\.isOnList) == [true, true, true, true])
        #expect(record.session.recipe.source == nil)
    }

    @Test func anIndexSavedByTheFirstBuildKeepsItsListsAndUnsentDeletes() throws {
        let index = try JSONDecoder().decode(LibraryIndex.self, from: Data(Self.indexFromTheFirstBuild.utf8))

        #expect(index.currentList == "6acab1afc5726b9df81a350b")
        #expect(index.deletingLists == ["6acab1afc5726b9df81a350c"])
        #expect(index.summaries.map(\.name) == ["Verify Fixture List"])
        #expect(index.recipes.map(\.totalMinutes) == [nil, 25])
        #expect(index.units == ["grams", "whole"])
        #expect(index.deletingRecipes.isEmpty)
    }

    @Test func anIndexSavedBeforeAddMealsKeepsItsRecipesWithNoIngredientCount() throws {
        let index = try JSONDecoder().decode(LibraryIndex.self, from: Data(Self.indexFromBeforeAddMeals.utf8))

        #expect(index.recipes == [
            RecipeSummary(
                id: "6ae9a8af3b1d1a5f0c2e7701", title: "Verify Fixture Traybake",
                imageURL: URL(string: "https://img.test/t.jpg"), totalMinutes: 45, rating: 5, sourceName: "example.com"),
            RecipeSummary(id: "6ae9a8af3b1d1a5f0c2e7702", title: "Verify Fixture Soft Egg"),
        ])
        #expect(index.currentList == "6ae9a8b03b1d1a5f0c2e7711")
        #expect(index.deletingRecipes == ["6ae9a8af3b1d1a5f0c2e7703"])
    }

    @Test func aListSavedBeforeWeeksIsAPlainListWithItsUnsentChanges() throws {
        let replica = try JSONDecoder().decode(ListReplica.self, from: Data(Self.listFromBeforeWeeks.utf8))

        #expect(replica.current?.name == "Weekend")
        #expect(replica.current?.items.map(\.name) == ["rice"])
        #expect(replica.current?.weekStart == nil)
        #expect(replica.current?.days == [])
        #expect(replica.pending.map(\.op) == [.rename("Weekend")])
    }

    @Test func recipesSavedBeforeWeeksHaveNoPlanningHistory() throws {
        let index = try JSONDecoder().decode(LibraryIndex.self, from: Data(Self.indexFromBeforeAddMeals.utf8))

        #expect(index.recipes.map(\.ingredientNames) == [[], []])
        #expect(index.recipes.map(\.lastPlannedOn) == [nil, nil])
        #expect(index.summaries.map(\.weekStart) == [nil])
    }

    /// The aisles were in the index before they had a file of their own.
    @MainActor @Test func aislesSavedInAnIndexAreStillReadAndOutliveTheNextIndexWritten() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "saved-files-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReplicaDisk(root: root)
        let index = #"{"aisleOrder":["Bakery","Dairy"],"unsentAisles":["Dairy","Bakery"],"units":["g"]}"#
        try Data(index.utf8).write(to: root.appending(path: "index.json"))

        #expect(disk.loadAisles() == AisleRecord(saved: ["Bakery", "Dairy"], owed: ["Dairy", "Bakery"]))

        disk.save(try #require(disk.loadIndex()))
        #expect(disk.loadAisles() == AisleRecord(saved: ["Bakery", "Dairy"], owed: ["Dairy", "Bakery"]))
        disk.save(AisleRecord(saved: ["Dairy"]))
        #expect(disk.loadAisles() == AisleRecord(saved: ["Dairy"]))
    }

    @MainActor @Test func aPhoneWithNothingSavedHasNoAisles() {
        let root = FileManager.default.temporaryDirectory.appending(path: "saved-files-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(ReplicaDisk(root: root).loadAisles() == nil)
    }

    @Test func anIndexWithNoFieldsAtAllLoadsEmpty() throws {
        #expect(try JSONDecoder().decode(LibraryIndex.self, from: Data("{}".utf8)) == LibraryIndex())
    }

    /// The decoders written by hand must carry every field, or one added later is silently dropped on load.
    @Test func everyFieldSurvivesBeingSavedAndLoaded() throws {
        let recipe = Recipe(
            id: "traybake", title: "Traybake", steps: ["Roast."],
            ingredients: [
                Recipe.Ingredient(
                    name: "oil", amount: 2, unit: "tbsp", note: "good", group: "For the dressing", category: "Pantry",
                    isOnList: false),
            ],
            baseServings: 4, rating: 5, imageURL: URL(string: "https://img.test/t.jpg"), totalMinutes: 45,
            source: RecipeSource(name: "example.com", url: URL(string: "https://example.com/t")),
            createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let start = try #require(PlanDate(iso: "2026-10-17"))
        var summary = recipe.summary
        (summary.lastPlannedOn, summary.cuisine) = (start.adding(days: -3), "British")
        let index = LibraryIndex(
            summaries: [ListSummary(id: "list", name: "Week", itemCount: 2, checkedCount: 1, meals: [], weekStart: start)],
            recipes: [summary], units: ["g"], deletingLists: ["gone"], currentList: "list", deletingRecipes: ["old"])
        let list = ListDetail(
            id: "list", name: "Week", recipes: ["traybake"], items: [], weekStart: start,
            days: [PlanDay(date: start, plan: .meal("traybake")), PlanDay(date: start.adding(days: 1), plan: .out)])

        #expect(try roundTrip(recipe) == recipe)
        #expect(try roundTrip(index) == index)
        #expect(try roundTrip(list) == list)
    }
}
