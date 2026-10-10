import Foundation
import Testing
@testable import Omlete

struct CookTextTests {
    @Test func aRangeTakesItsUpperBound() {
        #expect(detectTimers(in: "Simmer 10–12 mins until thick") == [DetectedTimer(label: "10–12 mins", seconds: 720, id: 0)])
    }

    @Test(arguments: [
        ("Bake for 45 minutes at 180C", 2700),
        ("Roast 1 hr 20 min", 4800),
        ("rest for a minute", 60),
        ("Rest for 30 seconds", 30),
        ("Pressure cook 10m", 600),
        ("Leave for two to three hours", 10800),
        ("Rest the dough for ½ hour", 1800),
        ("Simmer for 1½ hours", 5400),
    ])
    func readsATime(step: String, seconds: Int) {
        #expect(detectTimers(in: step).map(\.seconds) == [seconds])
    }

    @Test func findsSeveralAndNumbersThem() {
        let found = detectTimers(in: "Fry 5 mins, then simmer 20 minutes")

        #expect(found.map(\.seconds) == [300, 1200])
        #expect(found.map(\.id) == [0, 1])
    }

    @Test(arguments: [
        "Cut into 2 cm pieces and heat to 180C",
        "Roll out 2 m long",
        "Leave for 30 hours",
    ])
    func ignoresLengthsTemperaturesAndMoreThanADay(step: String) {
        #expect(detectTimers(in: step).isEmpty)
    }

    @Test func anAccentedWordBesideATimeIsNotAUnit() {
        #expect(detectTimers(in: "Añade 2 más y cuece 10 min").map(\.label) == ["10 min"])
        #expect(detectTimers(in: "Sauté 5 minutes, then flambé a minute").map(\.seconds) == [300, 60])
    }

    @Test func formatsAClock() {
        #expect(formatClock(75) == "1:15")
        #expect(formatClock(3700) == "1:01:40")
        #expect(formatClock(5) == "0:05")
        #expect(formatClock(-3) == "0:00")
    }

    @Test(arguments: [
        (500, 2, 1000), (1, 1.5, 1.5), (3, 0.5, 1.5), (7, 1.5, 11), (0.25, 0.5, 0.1), (1, 1.0 / 3, 0.3),
    ] as [(Double, Double, Double)])
    func scalesAnAmountAndKeepsItReadable(amount: Double, factor: Double, expected: Double) {
        #expect(scaleAmount(amount, by: factor) == expected)
    }

    @Test func noAmountScalesToNoAmount() {
        #expect(scaleAmount(nil, by: 2) == nil)
    }

    @Test func scalesTheQuantitiesWrittenIntoAStep() {
        #expect(scaleText("Add the 500g pasta and 2 tbsp oil", by: 2) == "Add the 1000g pasta and 4 tbsp oil")
        #expect(scaleText("Stir in 1.5 cups stock", by: 0.5) == "Stir in 0.8 cups stock")
        #expect(scaleText("Bake at 180C for 20 minutes", by: 2) == "Bake at 180C for 20 minutes")
        #expect(scaleText("Add the 500g pasta", by: 1) == "Add the 500g pasta")
    }

    @Test func aStepListsOnlyTheIngredientsItMentions() {
        let all = ["onions", "chopped tomatoes", "salt", "olive oil", "jalapeños"].map {
            Recipe.Ingredient(name: $0, amount: nil, unit: nil, note: nil)
        }

        #expect(ingredients(forStep: "Fry the onion in the oil, then add the tomato", in: all) == [0, 1])
        #expect(ingredients(forStep: "Dice the JALAPEÑO and season with salt", in: all) == [2, 4])
        #expect(ingredients(forStep: "Serve.", in: all).isEmpty)
    }
}
