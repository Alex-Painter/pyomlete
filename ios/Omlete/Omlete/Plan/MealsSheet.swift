import SwiftUI

/// "Add meals": pick several meals for a list without the sheet closing.
/// Discover's top picks come first, then the library, with one search over
/// both. Coming up with ideas is Discover's job; this only receives them.
struct MealsSheet: View {
    let list: ListDetail
    let store: ListStore

    @Environment(Library.self) private var library
    @Environment(Chef.self) private var chef
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    /// Recipes whose add is on the wire.
    @State private var adding: Set<RecipeID> = []

    var body: some View {
        let menu = MealMenu(
            recipes: library.recipesLoaded ? library.recipes : nil, cards: chef.visible, onList: Set(list.recipes), search: search)
        NavigationStack {
            List {
                Section {
                    SearchField(screen: "meals", prompt: "Search meals", text: $search)
                        .listRowInsets(EdgeInsets())
                } footer: {
                    Text("Tap meals to put their ingredients on \(list.name).")
                }

                if !menu.picks.isEmpty {
                    Section {
                        ForEach(menu.picks, content: pickRow)
                    } header: {
                        Label("Discover picks", systemImage: "sparkles")
                    }
                }

                Section("Your recipes") {
                    switch menu.library {
                    case .loading:
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    case .empty:
                        emptyLibrary
                    case .stocked where menu.recipes.isEmpty:
                        Text("No recipe matches.")
                            .foregroundStyle(.secondary)
                    case .stocked:
                        EmptyView()
                    }
                    ForEach(menu.recipes, content: recipeRow)
                }
            }
            .accessibilityIdentifier("meals.list")
            .contentMargins(.bottom, 72, for: .scrollContent)
            .navigationTitle("Add meals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("meals.doneButton")
                }
            }
            // Plan's banner is under this sheet, so the sheet draws it while it is up.
            .undoBanner()
        }
        .task { await library.refresh() }
        .task { await chef.load() }
    }

    private func pickRow(_ card: Suggestion) -> some View {
        let isSaving = card.stage == .saving
        return Button {
            // Not tied to this sheet: the save carries on after Done.
            Task { await chef.addToList(card.id, to: .list(list.id)) }
        } label: {
            PictureRow(picture: card.imageURL, title: card.title) {
                if let reason = card.reason {
                    Text(reason)
                        .lineLimit(1)
                }
            } mark: {
                if isSaving {
                    ProgressView()
                } else {
                    Image(systemName: "plus")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .accessibilityValue(isSaving ? "Saving" : "")
        .accessibilityIdentifier("meals.pick.\(card.id.rawValue)")
    }

    private func recipeRow(_ entry: MealMenu.Row) -> some View {
        let recipe = entry.recipe
        let isAdding = adding.contains(recipe.id)
        return Button {
            if entry.isOnList {
                store.removeMeal(recipe.id, title: recipe.title)
            } else {
                add(recipe)
            }
        } label: {
            PictureRow(picture: recipe.imageURL, title: recipe.title) {
                HStack(spacing: 10) {
                    if let count = recipe.ingredientCount {
                        Text("\(count) ingredient\(count == 1 ? "" : "s")")
                    }
                    if let minutes = recipe.totalMinutes {
                        Label(formatMinutes(minutes), systemImage: "clock")
                    }
                    if let rating = recipe.rating {
                        Label("\(rating)", systemImage: "star.fill")
                            .accessibilityLabel("\(rating) star\(rating == 1 ? "" : "s")")
                    }
                }
                .labelStyle(.captionLabel)
                .lineLimit(1)
            } mark: {
                if isAdding {
                    ProgressView()
                } else if entry.isOnList {
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
        .disabled(isAdding)
        .accessibilityValue(isAdding ? "Adding" : entry.isOnList ? "On the list" : "")
        .accessibilityAddTraits(entry.isOnList ? .isSelected : [])
        .accessibilityIdentifier("meals.recipe.\(recipe.id.rawValue)")
    }

    /// Both ways to fill the library are tabs, so each closes the sheet first.
    /// Plan stays open on its own tab's stack.
    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No recipes yet. Add one, or save something from Discover.")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Add a recipe") { leave(for: .add) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("meals.addRecipeButton")
                Button("Browse Discover") { leave(for: .discover) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("meals.browseDiscoverButton")
            }
        }
        .padding(.vertical, 4)
    }

    private func leave(for tab: AppTab) {
        dismiss()
        navigation.tab = tab
    }

    private func add(_ recipe: RecipeSummary) {
        adding.insert(recipe.id)
        Task {
            await library.addMeal(recipe.id, title: recipe.title, to: .list(list.id))
            adding.remove(recipe.id)
        }
    }
}

/// An icon and its text close together on one line, as a caption needs.
private struct CaptionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

private extension LabelStyle where Self == CaptionLabelStyle {
    static var captionLabel: CaptionLabelStyle { CaptionLabelStyle() }
}
