import SwiftUI

/// The evening a week's library ranks for, and what it ranks against.
struct LibraryDay {
    let day: PlanDay
    let items: [ListItem]
    let varietyDays: Int
    /// The calendar says you're out: no top three until you choose to plan anyway.
    var busy = false
}

/// The meal library, inline on Plan rather than in a sheet. On a week list it
/// picks the selected evening's dinner, ranked by how well each meal fits that
/// evening with the reason on each row and the top three on top; on a plain
/// list it adds meals, ranked by Not had lately unless sorted otherwise.
struct MealLibrary: View {
    /// What a row's tap will do, or that it is already done.
    enum Mark {
        case add, added, busy
    }

    let heading: String
    /// This week's days, counted as had already. Empty on a plain list.
    let days: [PlanDay]
    let today: PlanDate
    @Binding var query: MealLibraryQuery
    /// How a row says it is already done, such as "On the list".
    let addedValue: String
    let mark: (RecipeSummary) -> Mark
    let onPick: (RecipeSummary) -> Void
    /// Set on a week: rank for this evening.
    var forDay: LibraryDay? = nil

    @Environment(Library.self) private var library
    @Environment(AppNavigation.self) private var navigation

    static let scrollID = "plan.library"

    var body: some View {
        let recipes = library.recipes
        let history = MealLibraryQuery.withWeekHistory(recipes, days: days)
        let ranking = forDay.map {
            DayRanking(library: history, day: $0.day, days: days, items: $0.items, varietyDays: $0.varietyDays)
        }
        let rows = query.results(history, today: today, day: ranking)
        if let ranking, let forDay, forDay.day.plan != .out, !forDay.busy {
            TopThree(ranking: ranking, mark: mark, onPick: onPick)
                .id(forDay.day.date)
        }
        Section {
            SearchField(screen: "plan.library", prompt: "Dish or ingredient", text: $query.text)
                .listRowInsets(EdgeInsets())
                .id(Self.scrollID)
            filters(recipes)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            if !library.recipesLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if recipes.isEmpty {
                emptyLibrary
            } else if rows.isEmpty {
                Text("No meals match. Try fewer words or filters.")
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { recipe in
                row(recipe, mark: mark(recipe), fit: ranking?.fit(recipe.id))
            }
        } header: {
            HStack {
                Text(heading)
                Spacer()
                sortMenu
            }
        }
    }

    private func filters(_ recipes: [RecipeSummary]) -> some View {
        let all = MealLibraryQuery.Filter.fixed + (forDay == nil ? [] : [.usesList]) + MealLibraryQuery.Filter.tags(in: recipes)
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(all, id: \.self) { filter in
                    let isOn = query.filters.contains(filter)
                    Button(filter.title) { query.toggle(filter) }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(isOn ? .accentColor : .secondary)
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                        .accessibilityIdentifier("plan.library.filter.\(filter.id)")
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(MealLibraryQuery.Sort.allCases.filter { $0 != .best || forDay != nil }, id: \.self) { sort in
                Button {
                    query.sort = sort
                } label: {
                    if query.sort == sort {
                        Label(sort.title, systemImage: "checkmark")
                    } else {
                        Text(sort.title)
                    }
                }
                .accessibilityIdentifier("plan.library.sort.\(sort.rawValue)")
            }
        } label: {
            // Laid out by hand: in a List header a Label leaves a wide gutter after its icon.
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                Text(query.sort.title)
            }
            .font(.subheadline)
        }
        .accessibilityLabel("Sort, \(query.sort.title)")
        .accessibilityIdentifier("plan.library.sortMenu")
    }

    private func row(_ recipe: RecipeSummary, mark: Mark, fit: FitScore.Fit?) -> some View {
        Button {
            onPick(recipe)
        } label: {
            PictureRow(picture: recipe.imageURL, title: recipe.title) {
                HStack(spacing: 10) {
                    if let minutes = recipe.totalMinutes {
                        Label(formatMinutes(minutes), systemImage: "clock")
                    }
                    if let rating = recipe.rating {
                        Label("\(rating)", systemImage: "star.fill")
                            .accessibilityLabel("\(rating) star\(rating == 1 ? "" : "s")")
                    }
                    Text(fit?.reason ?? MealLibraryQuery.contextLine(recipe, today: today))
                        .foregroundStyle(fit?.clash == true ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                .labelStyle(.captionLabel)
                .lineLimit(1)
            } mark: {
                switch mark {
                case .busy:
                    ProgressView()
                case .added:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                case .add:
                    Image(systemName: "plus")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(mark == .busy)
        .accessibilityValue(mark == .busy ? "Adding" : mark == .added ? addedValue : "")
        .accessibilityAddTraits(mark == .added ? .isSelected : [])
        .accessibilityIdentifier("plan.library.recipe.\(recipe.id.rawValue)")
    }

    /// Both ways to fill the library are tabs. Plan hides the tab bar, so
    /// without these an empty library is a dead end; Plan stays open under its own tab.
    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No recipes yet. Add one, or save something from Discover.")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Add a recipe") { navigation.addRecipe() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("plan.library.addRecipeButton")
                Button("Browse Discover") { navigation.tab = .discover }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("plan.library.browseDiscoverButton")
            }
        }
        .padding(.vertical, 4)
    }
}

/// An icon and its text close together on one line, as a caption needs.
struct CaptionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

extension LabelStyle where Self == CaptionLabelStyle {
    static var captionLabel: CaptionLabelStyle { CaptionLabelStyle() }
}

/// The three best fits for the evening, each with its reason, so most dinners
/// are one glance and one tap. Something else shows the next three; skipping
/// one says "not tonight", never "not for me", so nothing is sent anywhere.
private struct TopThree: View {
    static let size = 3

    let ranking: DayRanking
    let mark: (RecipeSummary) -> MealLibrary.Mark
    let onPick: (RecipeSummary) -> Void

    @State private var page = 0

    var body: some View {
        // The day's own meal is already chosen; the rest are what you'd swap to.
        let pool = ranking.ranked.filter { $0.recipe.id != ranking.context.day.plan.meal }
        if !pool.isEmpty {
            let pages = (pool.count + Self.size - 1) / Self.size
            let start = (page % pages) * Self.size
            Section {
                ForEach(pool[start..<min(start + Self.size, pool.count)], id: \.recipe.id) { ranked in
                    card(ranked)
                }
                if pages > 1 {
                    Button {
                        page += 1
                    } label: {
                        Label((page + 1) % pages == 0 ? "Back to the top three" : "Something else", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("plan.topThree.somethingElseButton")
                }
            } header: {
                Text("Top three for \(ranking.context.day.date.dayLong)")
            }
        }
    }

    private func card(_ ranked: FitScore.Ranked) -> some View {
        let mark = mark(ranked.recipe)
        return Button {
            onPick(ranked.recipe)
        } label: {
            PictureRow(picture: ranked.recipe.imageURL, title: ranked.recipe.title) {
                VStack(alignment: .leading, spacing: 2) {
                    if let reason = ranked.fit.reason {
                        Text(reason)
                            .foregroundStyle(ranked.fit.clash ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                    if let minutes = ranked.recipe.totalMinutes {
                        Label(formatMinutes(minutes), systemImage: "clock")
                            .labelStyle(.captionLabel)
                            .foregroundStyle(.secondary)
                    }
                }
            } mark: {
                if mark == .added {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                } else {
                    Image(systemName: "plus")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(mark == .busy)
        .accessibilityAddTraits(mark == .added ? .isSelected : [])
        .accessibilityIdentifier("plan.topThree.recipe.\(ranked.recipe.id.rawValue)")
    }
}
