import Foundation
import SwiftUI
import Testing
@testable import Omlete

/// The rules of the web's recipe editor (`recipe.$recipeId.tsx`, the `editing` branch), which is the spec.
struct RecipeDraftTests {
    /// Two groups, a note, an ingredient kept off lists, one with no quantity and one the server sent without an aisle.
    private let traybake = Recipe(
        id: "traybake", title: "Traybake", steps: ["Roast.", "Dress.", "Serve."],
        ingredients: [
            .init(name: "chicken", amount: 6, unit: "whole", group: "For the traybake", category: "Meat & Fish"),
            .init(name: "potatoes", amount: 500, unit: "g", note: "halved", group: "For the traybake", category: "Fresh Produce"),
            .init(name: "oil", amount: 2, unit: "tbsp", group: "For the dressing", category: "Pantry", isOnList: false),
            .init(name: "salt", amount: nil, unit: "to taste"),
        ],
        baseServings: 4, rating: 5)

    private func edit(_ draft: RecipeDraft, sourceLocation: SourceLocation = #_sourceLocation) -> RecipeEdit? {
        guard case .save(let edit) = draft.outcome else {
            Issue.record("the draft cannot be saved", sourceLocation: sourceLocation)
            return nil
        }
        return edit
    }

    @Test func anUntouchedDraftSavesTheRecipeAsItIsAndHasNoChanges() {
        let draft = RecipeDraft(traybake)

        let saved = edit(draft)
        #expect(saved?.title == "Traybake")
        #expect(saved?.steps == traybake.steps)
        #expect(saved?.ingredients == traybake.ingredients)
        #expect(saved?.origins.map { $0?.index } == [0, 1, 2, 3])
        #expect(!draft.hasChanges)
    }

    @Test func aQuantityIsShownAsTextAndAMissingOneAsAnEmptyField() {
        let draft = RecipeDraft(traybake)

        #expect(draft.ingredients.map(\.quantity) == ["6", "500", "2", ""])
        #expect(draft.ingredients.map(\.unit) == ["whole", "g", "tbsp", "to taste"])
        #expect(draft.ingredients.map(\.aisle) == ["Meat & Fish", "Fresh Produce", "Pantry", nil])
    }

    @Test func anEmptiedQuantityIsSavedAsNoneAndNeverAsZero() {
        var draft = RecipeDraft(traybake)
        draft.ingredients[1].quantity = "  "

        #expect(edit(draft)?.ingredients[1].amount == nil)
        #expect(draft.hasChanges)
    }

    @Test(arguments: [("750", 750.0), ("1.5", 1.5), ("1,5", 1.5), (" 3 ", 3.0), ("0", 0.0), ("2.", 2.0)])
    func aTypedQuantityIsSavedAsThatNumber(typed: String, saved: Double) {
        var draft = RecipeDraft(traybake)
        draft.ingredients[1].quantity = typed

        #expect(edit(draft)?.ingredients[1].amount == saved)
    }

    @Test(arguments: ["a few", "1/2", "1.2.3", ".", "-2", "inf", "nan", "0x10", "1e3"])
    func aQuantityThatIsNotANumberStopsTheSaveAndNamesItsRow(typed: String) {
        var draft = RecipeDraft(traybake)
        draft.ingredients[2].quantity = typed

        #expect(draft.outcome == .fix(quantities: [draft.ingredients[2].id]))
        #expect(draft.hasChanges)
    }

    @Test func aBadQuantityOnARowWithNoNameIsDroppedWithTheRow() {
        var draft = RecipeDraft(traybake)
        draft.ingredients[2].name = " "
        draft.ingredients[2].quantity = "lots"

        #expect(edit(draft)?.ingredients.map(\.name) == ["chicken", "potatoes", "salt"])
    }

    @Test func aQuantityLeftAsShownKeepsTheDecimalsTheFieldDoesNotShow() {
        var third = traybake
        third.ingredients[0].amount = 1.0 / 3
        var draft = RecipeDraft(third)
        #expect(draft.ingredients[0].quantity == "0.33")

        draft.ingredients[0].name = "chicken thighs"

        #expect(edit(draft)?.ingredients[0].amount == 1.0 / 3)
    }

    @Test func whatTheEditorDoesNotShowIsSavedAsItWas() {
        var draft = RecipeDraft(traybake)
        draft.title = "Chicken traybake"
        for index in draft.ingredients.indices {
            draft.ingredients[index].name += " (edited)"
            draft.ingredients[index].quantity = "9"
            draft.ingredients[index].unit = "kg"
        }

        let saved = edit(draft)?.ingredients ?? []

        #expect(saved.map(\.note) == [nil, "halved", nil, nil])
        #expect(saved.map(\.group) == ["For the traybake", "For the traybake", "For the dressing", nil])
        #expect(saved.map(\.isOnList) == [true, true, false, true])
        #expect(saved.map(\.category) == ["Meat & Fish", "Fresh Produce", "Pantry", nil])
    }

    @Test func aPickedAisleIsSaved() {
        var draft = RecipeDraft(traybake)
        draft.ingredients[3].aisle = "Pantry"

        #expect(edit(draft)?.ingredients[3].category == "Pantry")
        #expect(draft.hasChanges)
    }

    @Test func namesUnitsAndStepsAreTrimmedAndAnEmptiedUnitIsNone() {
        var draft = RecipeDraft(traybake)
        draft.ingredients[0].name = "  chicken thighs \n"
        draft.ingredients[0].unit = " "
        draft.ingredients[1].unit = " kg "
        draft.steps[0].text = "  Roast for 40 mins.\n"

        let saved = edit(draft)

        #expect(saved?.ingredients[0].name == "chicken thighs")
        #expect(saved?.ingredients[0].unit == nil)
        #expect(saved?.ingredients[1].unit == "kg")
        #expect(saved?.steps[0] == "Roast for 40 mins.")
    }

    @Test func ingredientsWithNoNameAndBlankStepsAreDropped() {
        var draft = RecipeDraft(traybake)
        draft.ingredients[1].name = "   "
        draft.steps[1].text = "\n"

        let saved = edit(draft)

        #expect(saved?.ingredients.map(\.name) == ["chicken", "oil", "salt"])
        #expect(saved?.steps == ["Roast.", "Serve."])
        #expect(draft.hasChanges)
    }

    @Test func theTitleIsTrimmedAndAnEmptiedOneKeepsTheRecipesOwn() {
        var draft = RecipeDraft(traybake)

        draft.title = "  Sunday traybake "
        #expect(edit(draft)?.title == "Sunday traybake")

        draft.title = "   "
        #expect(edit(draft)?.title == "Traybake")
        #expect(!draft.hasChanges)
    }

    /// The last ingredient here has no group, so neither has the added one.
    @Test func anAddedIngredientIsOnListsOnTheFallbackAisleWithNoNote() {
        var draft = RecipeDraft(traybake)
        let id = draft.addIngredient()
        #expect(draft.ingredients.last?.id == id)

        draft.ingredients[4].name = "lemon"
        draft.ingredients[4].quantity = "1"

        #expect(edit(draft)?.ingredients.last == Recipe.Ingredient(name: "lemon", amount: 1, category: "Other"))
        #expect(edit(draft)?.origins.last == .some(nil))
    }

    /// With no group it would show on the recipe page alone, under a heading of its own.
    @Test func anIngredientAddedToAGroupedRecipeJoinsTheLastGroup() {
        var grouped = traybake
        grouped.ingredients.removeLast()
        var draft = RecipeDraft(grouped)

        draft.addIngredient()
        draft.ingredients[3].name = "capers"
        draft.addIngredient()
        draft.ingredients[4].name = "lemon"

        let saved = edit(draft)
        #expect(saved?.ingredients.map(\.group) == ["For the traybake", "For the traybake", "For the dressing", "For the dressing", "For the dressing"])
        #expect(saved?.ingredients[3] == Recipe.Ingredient(name: "capers", group: "For the dressing", category: "Other"))

        var served = grouped
        served.ingredients = saved?.ingredients ?? []
        #expect(served.ingredientGroups.map(\.heading) == ["For the traybake", "For the dressing"])
        #expect(saved?.carryingUntouched(from: grouped).ingredients.map(\.group) == saved?.ingredients.map(\.group))
    }

    @Test func anIngredientAddedAfterTheLastGroupWasRemovedJoinsTheOneNowLast() {
        var grouped = traybake
        grouped.ingredients.removeLast()
        var draft = RecipeDraft(grouped)
        draft.ingredients.removeLast()

        draft.addIngredient()
        draft.ingredients[2].name = "capers"

        #expect(edit(draft)?.ingredients.last?.group == "For the traybake")
    }

    /// Added while the dressing was last, saved after it was removed: not alone under "For the dressing".
    @Test func anIngredientAddedBeforeTheLastGroupWasRemovedJoinsTheOneNowLast() {
        var grouped = traybake
        grouped.ingredients.removeLast()
        var draft = RecipeDraft(grouped)

        draft.addIngredient()
        draft.ingredients[3].name = "capers"
        draft.ingredients.remove(at: 2)

        #expect(edit(draft)?.ingredients.last?.group == "For the traybake")
    }

    /// The group is the recipe's as it is at save time, like the other fields the editor does not touch.
    @Test func anAddedIngredientFollowsAGroupRenamedSinceTheEditorOpened() {
        var grouped = traybake
        grouped.ingredients.removeLast()
        var draft = RecipeDraft(grouped)
        draft.addIngredient()
        draft.ingredients[3].name = "capers"
        var now = grouped
        now.ingredients[2].group = "For the sauce"

        #expect(edit(draft)?.carryingUntouched(from: now).ingredients.suffix(2).map(\.group) == ["For the sauce", "For the sauce"])
    }

    /// Cancel then Undo offers the draft back when this holds.
    @Test func aDraftIsStillBasedOnARecipeWhoseUneditableFieldsChanged() {
        var draft = RecipeDraft(traybake)
        draft.title = "Chicken traybake"
        var now = traybake
        now.ingredients[0].isOnList = false
        now.ingredients[1].note = "quartered"
        now.rating = 2

        #expect(draft.isBased(on: now))
        #expect(draft.isBased(on: traybake))
        #expect(edit(draft)?.carryingUntouched(from: now).ingredients.map(\.isOnList) == [false, true, false, true])
    }

    @Test func aDraftIsNotBasedOnARecipeEditedSince() {
        let draft = RecipeDraft(traybake)
        var retitled = traybake
        retitled.title = "Roast"
        var requantified = traybake
        requantified.ingredients[1].amount = 750
        var reaisled = traybake
        reaisled.ingredients[3].category = "Pantry"
        var shorter = traybake
        shorter.ingredients.removeLast()
        var restepped = traybake
        restepped.steps[0] = "Roast for an hour."

        for changed in [retitled, requantified, reaisled, shorter, restepped] {
            #expect(!draft.isBased(on: changed))
        }
    }

    @Test func anAddedRowLeftBlankIsNotAChange() {
        var draft = RecipeDraft(traybake)
        draft.addIngredient()
        draft.addStep()

        #expect(!draft.hasChanges)
        #expect(edit(draft)?.ingredients == traybake.ingredients)
    }

    @Test func anAddedStepGoesLastAndIsSaved() {
        var draft = RecipeDraft(traybake)
        draft.addStep()
        draft.steps[3].text = "Eat."

        #expect(edit(draft)?.steps == ["Roast.", "Dress.", "Serve.", "Eat."])
    }

    @Test func removedRowsAreNotSaved() {
        var draft = RecipeDraft(traybake)
        draft.ingredients.remove(at: 0)
        draft.steps.remove(at: 2)

        let saved = edit(draft)

        #expect(saved?.ingredients.map(\.name) == ["potatoes", "oil", "salt"])
        #expect(saved?.steps == ["Roast.", "Dress."])
        #expect(draft.hasChanges)
    }

    @Test func movedStepsAreSavedInTheirNewOrderAndMovingBackIsNoChange() {
        var draft = RecipeDraft(traybake)

        draft.steps.move(fromOffsets: [2], toOffset: 0)
        #expect(edit(draft)?.steps == ["Serve.", "Roast.", "Dress."])
        #expect(draft.hasChanges)

        draft.steps.move(fromOffsets: [0], toOffset: 3)
        #expect(!draft.hasChanges)
    }

    @Test func aFieldRetypedAsItWasIsNotAChange() {
        var draft = RecipeDraft(traybake)
        draft.title = "Traybake "
        draft.ingredients[0].quantity = "6"
        draft.ingredients[3].unit = "to taste"

        #expect(!draft.hasChanges)
    }

    @Test func everyRowKeepsItsOwnIdThroughAddsRemovalsAndMoves() {
        var draft = RecipeDraft(traybake)
        let roast = draft.steps[0].id
        let potatoes = draft.ingredients[1].id

        draft.ingredients.remove(at: 0)
        draft.steps.remove(at: 1)
        let lemon = draft.addIngredient()
        let eat = draft.addStep()
        draft.steps.move(fromOffsets: [0], toOffset: 3)
        let another = draft.addStep()

        #expect(draft.steps.last(where: { $0.text == "Roast." })?.id == roast)
        #expect(draft.ingredients[0].id == potatoes)
        let ids = draft.ingredients.map(\.id) + draft.steps.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(Set([lemon, eat, another]).isDisjoint(with: 0..<7))
    }

    @Test func aRecipeWithNothingInItCanStillBeGivenRows() {
        var draft = RecipeDraft(Recipe(id: "blank", title: "Blank", steps: [], ingredients: []))
        let ingredient = draft.addIngredient()
        let step = draft.addStep()

        #expect(ingredient != step)
        #expect(!draft.hasChanges)
    }

    @Test func unitsOfferedAreTheServersThenTheWebsThreeEachOnce() {
        #expect(RecipeEditor.unitChoices(server: ["g", "", "Whole", "tbsp"]) == ["g", "Whole", "tbsp", "to taste", "pinch"])
        #expect(RecipeEditor.unitChoices(server: []) == ["to taste", "whole", "pinch"])
    }
}
