import Testing
@testable import Omlete

/// Ports of `client/src/lib/parseItems.test.ts`, case for case.
struct ParseItemTests {
    @Test func readsALeadingCount() {
        #expect(parseItem("2 onions") == ParsedItem(name: "onions", amount: 2, unit: nil))
    }

    @Test func readsAUnitGluedToTheNumber() {
        #expect(parseItem("500g mince") == ParsedItem(name: "mince", amount: 500, unit: "g"))
    }

    @Test func readsASpelledOutUnitAndDropsOf() {
        #expect(parseItem("2 litres of milk") == ParsedItem(name: "milk", amount: 2, unit: "l"))
    }

    @Test func keepsANonUnitWordInTheName() {
        #expect(parseItem("2 large onions") == ParsedItem(name: "large onions", amount: 2, unit: nil))
    }

    @Test func readsFractions() {
        #expect(parseItem("½ tsp cumin") == ParsedItem(name: "cumin", amount: 0.5, unit: "tsp"))
        #expect(parseItem("1/2 lemon") == ParsedItem(name: "lemon", amount: 0.5, unit: nil))
    }

    @Test func readsATrailingCount() {
        #expect(parseItem("eggs x12") == ParsedItem(name: "eggs", amount: 12, unit: nil))
    }

    @Test func leavesPlainNamesAlone() {
        #expect(parseItem("crème fraîche") == ParsedItem(name: "crème fraîche", amount: nil, unit: nil))
    }

    @Test func stripsBulletsFromPastedLists() {
        #expect(parseItem("- bread")?.name == "bread")
        #expect(parseItem("• 3 apples") == ParsedItem(name: "apples", amount: 3, unit: nil))
    }
}

struct ParseItemsTests {
    @Test func splitsCommas() {
        #expect(parseItems("milk, eggs, bread").map(\.name) == ["milk", "eggs", "bread"])
    }

    @Test func splitsAPastedMultiLineListAndSkipsBlanks() {
        #expect(parseItems("2 onions\n\n500g mince\n- rice").count == 3)
    }

    @Test func splitsWindowsLineEndings() {
        #expect(parseItems("milk\r\neggs").map(\.name) == ["milk", "eggs"])
    }
}

struct FormatQuantityTests {
    @Test func gluesMetricUnits() {
        #expect(formatQuantity(500, "g") == "500g")
        #expect(formatQuantity(2, "tin") == "2 tin")
        #expect(formatQuantity(nil, "to taste") == "to taste")
    }

    @Test func shortensRecipeUnits() {
        #expect(formatQuantity(400, "grams") == "400g")
        #expect(formatQuantity(1, "whole") == "1")
    }

    @Test func roundsToTwoPlacesWithNoTrailingZeros() {
        #expect(formatQuantity(1.0 / 3, nil) == "0.33")
        #expect(formatQuantity(1.5, "kg") == "1.5kg")
        #expect(formatQuantity(2.001, nil) == "2")
    }
}
