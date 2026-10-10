import Testing
@testable import Omlete

struct GuessCategoryTests {
    let aisles = ["Fresh Produce", "Meat & Fish", "Dairy & Eggs", "Bakery", "Frozen", "Drinks", "Household", "Pantry & Dry Goods", "Other"]

    @Test(arguments: [
        ("onions", "Fresh Produce"),
        ("Chicken thighs", "Meat & Fish"),
        ("crème fraîche", "Dairy & Eggs"),
        ("sourdough loaf", "Bakery"),
        ("frozen peas", "Fresh Produce"),
        ("ice cream", "Dairy & Eggs"),
        ("green tea", "Drinks"),
        ("bin bags", "Household"),
        ("basmati rice", "Pantry & Dry Goods"),
        ("light bulbs", "Other"),
    ])
    func picksTheFirstAisleWhoseKeywordMatches(name: String, aisle: String) {
        #expect(guessCategory(name, categories: aisles) == aisle)
    }

    @Test func anItemAlreadyOnTheListKeepsItsAisle() {
        let existing = [ListItem(id: "1", name: "Onions", amount: nil, unit: nil, category: "Bakery", checked: false, sources: [])]
        #expect(guessCategory(" onions ", categories: aisles, existing: existing) == "Bakery")
    }

    @Test func skipsAnAisleTheUserDoesNotHave() {
        #expect(guessCategory("onions", categories: ["Bakery", "Other"]) == "Other")
    }

    @Test func fallsBackToTheLastAisleWhenThereIsNoOther() {
        #expect(guessCategory("candles", categories: ["Bakery", "Drinks"]) == "Drinks")
        #expect(guessCategory("candles", categories: []) == "Other")
    }
}
