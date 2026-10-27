import SwiftUI

/// The meal library, inline on Plan rather than in a sheet. On a week list it
/// picks the selected evening's dinner; on a plain list it adds meals. Rows
/// rank by Not had lately unless sorted otherwise.
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

    @Environment(Library.self) private var library
    @Environment(AppNavigation.self) private var navigation

    static let scrollID = "plan.library"

    var body: some View {
        let recipes = library.recipes
        let rows = query.results(MealLibraryQuery.withWeekHistory(recipes, days: days), today: today)
        Section {
            SearchField(screen: "plan.library", prompt: "Dish or ingredient", text: $query.text)
                .listRowInsets(EdgeInsets())
                .id(Self.scrollID)
            filters
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
                row(recipe, mark: mark(recipe))
            }
        } header: {
            HStack {
                Text(heading)
                Spacer()
                sortMenu
            }
        }
    }

    private var filters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(MealLibraryQuery.Filter.allCases, id: \.self) { filter in
                    let isOn = query.filters.contains(filter)
                    Button(filter.title) { query.toggle(filter) }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(isOn ? .accentColor : .secondary)
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                        .accessibilityIdentifier("plan.library.filter.\(filter.rawValue)")
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(MealLibraryQuery.Sort.allCases, id: \.self) { sort in
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

    private func row(_ recipe: RecipeSummary, mark: Mark) -> some View {
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
                    Text(MealLibraryQuery.contextLine(recipe, today: today))
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
                Button("Add a recipe") { navigation.tab = .add }
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
