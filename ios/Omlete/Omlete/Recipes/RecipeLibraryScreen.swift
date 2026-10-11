import SwiftUI

/// Recipes: everything saved, as a grid of pictures you can search, sort and
/// filter. When it is empty it points at the two ways to fill it.
struct RecipeLibraryScreen: View {
    @Environment(Library.self) private var library
    @Environment(AppNavigation.self) private var navigation

    @State private var query = LibraryQuery()

    var body: some View {
        let recipes = library.recipes
        let shown = query.apply(to: recipes)
        ScrollView {
            if !recipes.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    searchField
                    filters
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                        ForEach(shown) { recipe in
                            NavigationLink(value: Route.recipe(recipe.id)) {
                                RecipeTile(recipe: recipe)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("recipes.tile.\(recipe.id.rawValue)")
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 8)
            }
        }
        .accessibilityIdentifier("recipes.grid")
        .overlay {
            if recipes.isEmpty {
                emptyState
            } else if shown.isEmpty {
                ContentUnavailableView(
                    "Nothing matches", systemImage: "magnifyingglass",
                    description: Text("Try another search or filter."))
            }
        }
        .contentMargins(.bottom, 72, for: .scrollContent)
        .background(Color(.systemGroupedBackground))
        .undoBanner(isCovered: navigation.immersive != nil)
        .navigationTitle("Recipes")
        .navigationSubtitle(recipes.isEmpty ? "" : "\(recipes.count) saved")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Sort", systemImage: "arrow.up.arrow.down") {
                    ForEach(LibraryQuery.Sort.allCases, id: \.self) { sort in
                        Button {
                            query.sort = sort
                        } label: {
                            if query.sort == sort {
                                Label(sort.title, systemImage: "checkmark")
                            } else {
                                Text(sort.title)
                            }
                        }
                        .accessibilityIdentifier("recipes.sort.\(sort.rawValue)")
                    }
                }
                .accessibilityIdentifier("recipes.sortMenu")
            }
        }
        .refreshable { await library.refresh() }
        .task { await library.refresh() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search recipes", text: $query.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier("recipes.searchField")
            if !query.search.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { query.search = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("recipes.clearSearchButton")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    private var filters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(LibraryQuery.Filter.allCases, id: \.self) { filter in
                    let isOn = query.filter == filter
                    Button(filter.title) { query.filter = isOn ? nil : filter }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(isOn ? .accentColor : .secondary)
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                        .accessibilityIdentifier("recipes.filter.\(filter.rawValue)")
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder private var emptyState: some View {
        if library.hasLoaded {
            ContentUnavailableView {
                Label("No recipes yet", systemImage: "book")
            } description: {
                Text("Paste a link, describe a dish, or save one from Discover.")
            } actions: {
                Button("Add a recipe") { navigation.tab = .add }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("recipes.addRecipeButton")
                Button("Browse Discover") { navigation.tab = .discover }
                    .accessibilityIdentifier("recipes.browseDiscoverButton")
            }
        } else if let failure = library.loadFailure {
            LoadFailure(failure: failure, retryIdentifier: "recipes.retryButton") { await library.refresh() }
        } else {
            ProgressView()
        }
    }
}

private struct RecipeTile: View {
    let recipe: RecipeSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecipePicture(url: recipe.imageURL)
                .aspectRatio(4 / 3, contentMode: .fit)
            VStack(alignment: .leading, spacing: 6) {
                Text(recipe.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 10) {
                        if let rating = recipe.rating {
                            caption("\(rating)", systemImage: "star.fill", tint: .yellow)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("\(rating) star\(rating == 1 ? "" : "s")")
                        }
                        if let minutes = recipe.totalMinutes {
                            caption(formatMinutes(minutes), systemImage: "clock")
                        }
                    }
                    if let source = recipe.sourceName {
                        Text(source)
                            .lineLimit(1)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                // Room for both lines in every tile, so a row of tiles ends level.
                .frame(minHeight: 36, alignment: .topLeading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    private func caption(_ text: String, systemImage: String, tint: Color? = nil) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            Text(text)
        }
        .fixedSize()
    }
}
