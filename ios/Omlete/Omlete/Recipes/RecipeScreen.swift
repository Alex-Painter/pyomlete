import SwiftUI

/// One recipe: what it needs and how it is made, with the two things you do
/// with it, Cook and Add to list, at the top. Each ingredient says whether it
/// goes on shopping lists, so salt can be turned off once and stay off.
struct RecipeScreen: View {
    let recipeID: RecipeID

    @Environment(Kitchen.self) private var kitchen
    @Environment(Library.self) private var library
    @Environment(AppNavigation.self) private var navigation
    @Environment(UndoCenter.self) private var undo
    @Environment(\.dismiss) private var dismiss

    /// The edit in progress, which is what puts the editor up.
    @State private var editing: RecipeDraft?
    /// Edit was tapped and the recipe store is being asked what it may start from.
    @State private var isStartingEdit = false
    /// The banner offering a discarded edit back is up.
    @State private var discardOffered = false

    var body: some View {
        let store = kitchen.cook(recipeID)
        Group {
            switch store.page {
            case .loading:
                ProgressView()
            case .gone:
                ContentUnavailableView(
                    "This recipe doesn't exist any more.", systemImage: "trash",
                    description: Text("It may have been deleted."))
            case .unavailable:
                ContentUnavailableView {
                    Label("Couldn't reach Omlete. Check your connection.", systemImage: "wifi.slash")
                } actions: {
                    Button("Try again") {
                        Task { await store.load() }
                    }
                    .accessibilityIdentifier("recipe.retryButton")
                }
            case .ready(let recipe):
                page(recipe, in: store)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .undoBanner(isCovered: navigation.immersive != nil)
        .task { await store.load() }
        .task(id: isStartingEdit) {
            if isStartingEdit { await startEdit(in: store) }
        }
    }

    private func page(_ recipe: Recipe, in store: CookStore) -> some View {
        List {
            Section {
                if let picture = recipe.imageURL {
                    RecipePicture(url: picture)
                        .frame(height: 220)
                        .listRowInsets(EdgeInsets())
                }
                header(recipe)
                actions(recipe, in: store)
            }

            ForEach(recipe.ingredientGroups) { group in
                Section {
                    ForEach(group.lines) { line in
                        HStack(spacing: 12) {
                            RecipeIngredientRow(ingredient: line.ingredient)
                            onListToggle(line, in: store)
                        }
                    }
                } header: {
                    Text(group.heading ?? "Ingredients")
                } footer: {
                    if group.id == recipe.ingredientGroups.last?.id {
                        Text("Turn off anything you always have, like salt. It won't go on shopping lists.")
                    }
                }
            }

            if !recipe.steps.isEmpty {
                Section("Method") {
                    ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                        RecipeStepRow(number: index + 1, text: step)
                    }
                }
            }
        }
        .contentMargins(.bottom, 72, for: .scrollContent)
        .accessibilityIdentifier("recipe.page")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("More actions", systemImage: "ellipsis") {
                    Button("Edit recipe", systemImage: "pencil") { isStartingEdit = true }
                        .disabled(isStartingEdit)
                        .accessibilityIdentifier("recipe.editAction")
                    Button("Delete recipe", systemImage: "trash", role: .destructive) {
                        library.deleteRecipe(recipe.id, title: recipe.title)
                        dismiss()
                    }
                    .accessibilityIdentifier("recipe.deleteAction")
                }
                .accessibilityIdentifier("recipe.moreMenu")
            }
        }
        .sheet(item: $editing) { draft in
            RecipeEditor(draft: draft, store: store, aisles: library.aisleOrder, units: library.units) { discarded in
                discardOffered = true
                undo.offer("Discarded your changes to \(recipe.title)", undo: {
                    discardOffered = false
                    restore(discarded, in: store)
                }, commit: {
                    discardOffered = false
                })
            }
        }
        // The Undo reopens the editor on this page, so it must not outlive it.
        .onDisappear {
            if discardOffered { undo.commitNow() }
        }
    }

    /// Runs under `.task(id:)`, so asking the server ends with the page. The
    /// refusal is news that may arrive seconds after the tap, so it waits
    /// its turn behind a banner that still offers Undo.
    private func startEdit(in store: CookStore) async {
        defer { isStartingEdit = false }
        let start = await store.recipeToEdit()
        guard !Task.isCancelled else { return }
        switch start {
        case .ready(let recipe):
            editing = RecipeDraft(recipe)
        case .gone:
            break
        case .unavailable(.unreachable):
            undo.inform("Couldn't reach Omlete. Editing a recipe needs a connection.")
        case .unavailable:
            undo.inform("Couldn't load this recipe to edit. Try again.")
        }
    }

    /// A discarded draft is only as good as the recipe it was made from. If
    /// something the editor edits changed while the banner was up, saving the
    /// draft would put the old value back, so it is not reopened. A rating or
    /// an On list toggle is no such change: a save sends those as they are then.
    private func restore(_ discarded: RecipeDraft, in store: CookStore) {
        if case .ready(let now) = store.page, discarded.isBased(on: now) {
            editing = discarded
        } else {
            undo.offer("The recipe has changed since, so that edit can't be brought back.")
        }
    }

    private func header(_ recipe: Recipe) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(recipe.title)
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("recipe.title")
            RecipeMeta(recipe: recipe)
            if let added = recipe.createdAt {
                Text("Added \(added.formatted(.dateTime.day().month(.abbreviated).year()))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func actions(_ recipe: Recipe, in store: CookStore) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    navigation.startCooking(recipe.id)
                } label: {
                    Label("Cook", systemImage: "frying.pan")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 8)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(.systemBackground))
                .padding(.horizontal, 12)
                .background(.primary, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("recipe.cookButton")

                AddToListButton(identifier: "recipe.addToList") {
                    await library.addMeal(recipe.id, title: recipe.title, to: $0)
                }
            }
            HStack(spacing: 4) {
                Text("Your rating")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                StarRating(stars: store.rating.stars, identifier: "recipe.star", size: 22, onRate: store.rate)
            }
            if store.rating.status == .savedHere {
                Text(store.rating.status.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func onListToggle(_ line: Recipe.IngredientGroup.Line, in store: CookStore) -> some View {
        let isOn = line.ingredient.isOnList
        return Button(isOn ? "On list" : "Not on list") { store.setOnList(line.id, !isOn) }
            .font(.caption.weight(.medium))
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(isOn ? .orange : .secondary)
            .accessibilityLabel("\(line.ingredient.name): \(isOn ? "on shopping lists" : "not on shopping lists")")
            .accessibilityAddTraits(isOn ? .isSelected : [])
            .accessibilityIdentifier("recipe.onList.\(line.id)")
    }
}
