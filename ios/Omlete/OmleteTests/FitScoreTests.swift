import Foundation
import Testing
@testable import Omlete

/// The cases in `docs/fixtures/fit-score-cases.json`, which the web's
/// `fitScore.test.ts` runs too: both must rank every case the same way.
struct FitScoreCase: Decodable, Sendable, CustomTestStringConvertible {
    struct Recipe: Decodable, Sendable {
        let id: String
        let title: String
        let tags: String?
        let rating: Int?
        let total_minutes: Int?
        let last_planned_on: String?
        let ingredients: [String]?
    }

    struct Item: Decodable, Sendable {
        let name: String
        let category: String
        let from: [String]
    }

    let name: String
    let week_start: String?
    let day: String
    let quick: Bool?
    let variety_days: Int?
    let week: [String: String]
    let items: [Item]?
    let recipes: [Recipe]
    let order: [String]
    /// A null value means no reason, so these are kept as JSON values.
    let reasons: [String: String?]?
    let clash: [String]?

    var testDescription: String { name }

    /// Read from the repository, so the web and this port share one file.
    static let all: [FitScoreCase] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "../../../docs/fixtures/fit-score-cases.json")
        struct File: Decodable { let cases: [FitScoreCase] }
        return try! JSONDecoder().decode(File.self, from: Data(contentsOf: url)).cases
    }()

    static func tags(_ short: String?) -> RecipeTags? {
        guard let parts = short?.split(separator: " ").map(String.init), parts.count == 4 else { return nil }
        return RecipeTags(base: parts[0], main: parts[1], mood: parts[2], cuisine: parts[3])
    }

    func load() -> (recipes: [RecipeSummary], context: FitScore.Context) {
        let recipes = self.recipes.map { r in
            RecipeSummary(
                id: RecipeID(r.id), title: r.title, totalMinutes: r.total_minutes, rating: r.rating,
                lastPlannedOn: r.last_planned_on.flatMap(PlanDate.init(iso:)), ingredientNames: r.ingredients ?? [],
                tags: Self.tags(r.tags))
        }
        let target = PlanDate(iso: day)!
        let days: [PlanDay] = week_start.map { start in
            (0..<7).map { offset in
                let date = PlanDate(iso: start)!.adding(days: offset)
                return PlanDay(
                    date: date, plan: week[date.iso].map { .meal(RecipeID($0)) } ?? .open,
                    quick: date == target && quick == true)
            }
        } ?? []
        let items = (self.items ?? []).enumerated().map { index, entry in
            ListItem(
                id: ItemID("item-\(index)"), name: entry.name, amount: nil, unit: nil, category: entry.category,
                checked: false, sources: entry.from.map { ItemSource(recipeID: RecipeID($0), amount: nil) })
        }
        let day = days.first { $0.date == target } ?? PlanDay(date: target, plan: .open, quick: quick == true)
        let context = FitScore.Context(day: day, days: days, recipes: recipes, items: items, varietyDays: variety_days ?? 3)
        return (recipes, context)
    }
}

struct FitScoreTests {
    @Test(arguments: FitScoreCase.all)
    func sharedCase(_ c: FitScoreCase) {
        let (recipes, context) = c.load()
        let ranked = FitScore.rank(recipes, for: context)
        #expect(ranked.map(\.recipe.id.rawValue) == c.order)
        let fits = Dictionary(uniqueKeysWithValues: ranked.map { ($0.recipe.id.rawValue, $0.fit) })
        for (id, reason) in c.reasons ?? [:] {
            #expect(fits[id]?.reason == reason, "\(id)")
        }
        if let clash = c.clash {
            #expect(ranked.filter(\.fit.clash).map(\.recipe.id.rawValue).sorted() == clash.sorted())
        }
    }

    @Test func theFixtureHasEveryCase() {
        #expect(FitScoreCase.all.count == 25)
    }

    @Test func reuseStaysBelowTheSmallestVarietyPenalty() {
        let smallest = [
            FitScore.Weight.sameRecipe, FitScore.Weight.sameBase, FitScore.Weight.quickNight,
            FitScore.Weight.sameMain, FitScore.Weight.sameCuisine,
        ].min()!
        #expect(FitScore.Weight.sharedCap < smallest)
    }

    /// The web's seeded generator, so a failure names a library that can be replayed.
    private struct Seeded {
        var seed: Int
        mutating func next() -> Double {
            seed = (seed * 1_103_515_245 + 12345) % 2_147_483_648
            return Double(seed) / 2_147_483_648
        }
        mutating func pick<T>(_ values: [T]) -> T { values[Int(next() * Double(values.count))] }
    }

    @Test func aClashNeverRanksAboveACleanMealWithTheSameRatingOver200RandomWeeks() {
        let bases = ["rice", "pasta", "potatoes", "bread", "noodles", "none"]
        let mains = ["chicken", "beef", "pork", "lamb", "fish", "veggie", "beans"]
        let cuisines = ["italian", "indian", "british", "south_east_asian", "mexican"]
        let foods = ["spinach", "feta", "coriander", "lime", "chicken", "cream"]
        let start = PlanDate(iso: "2026-10-17")!
        for seed in 1...200 {
            var random = Seeded(seed: seed)
            let recipes = (0..<30).map { index in
                RecipeSummary(
                    id: RecipeID("r\(index)"), title: "r\(index)",
                    totalMinutes: nil, rating: nil,
                    tags: RecipeTags(base: random.pick(bases), main: random.pick(mains), mood: "fresh", cuisine: random.pick(cuisines)))
            }.map { recipe in
                var recipe = recipe
                recipe.rating = random.next() < 0.7 ? 1 + Int(random.next() * 5) : nil
                recipe.totalMinutes = 10 + Int(random.next() * 80)
                recipe.lastPlannedOn = random.next() < 0.5 ? start.adding(days: -Int(random.next() * 90)) : nil
                recipe.ingredientNames = foods.filter { _ in random.next() < 0.3 }
                return recipe
            }
            let days = (0..<7).map { offset in
                let meal: DayPlan = random.next() < 0.4 ? .meal(random.pick(recipes).id) : .open
                return PlanDay(date: start.adding(days: offset), plan: meal, quick: random.next() < 0.2)
            }
            let items = foods.enumerated().map { index, name in
                ListItem(
                    id: ItemID("i\(index)"), name: name, amount: nil, unit: nil, category: "Fresh Produce", checked: false,
                    sources: [ItemSource(recipeID: random.pick(recipes).id, amount: nil)])
            }
            let target = random.pick(days)
            let context = FitScore.Context(day: target, days: days, recipes: recipes, items: items, varietyDays: 3)
            let ranked = FitScore.rank(recipes, for: context)
            for (index, a) in ranked.enumerated() where a.fit.clash {
                for b in ranked[(index + 1)...] where !b.fit.clash && b.recipe.rating == a.recipe.rating {
                    Issue.record("seed \(seed): \(a.recipe.id.rawValue) clashes but ranks above \(b.recipe.id.rawValue)")
                }
            }
        }
    }

    @Test func anUntaggedMealTakesNoTagSignal() {
        let pasta = RecipeSummary(id: "pasta", title: "pasta", tags: FitScoreCase.tags("pasta pork comforting italian"))
        let untagged = RecipeSummary(id: "u", title: "u")
        let days = [
            PlanDay(date: PlanDate(iso: "2026-10-19")!, plan: .meal("pasta")),
            PlanDay(date: PlanDate(iso: "2026-10-20")!, plan: .open),
        ]
        let context = FitScore.Context(day: days[1], days: days, recipes: [pasta, untagged], items: [], varietyDays: 3)
        #expect(FitScore.fit(untagged, context) == FitScore.Fit(score: FitScore.Weight.neverPlanned, reason: nil, clash: false))
    }
}
