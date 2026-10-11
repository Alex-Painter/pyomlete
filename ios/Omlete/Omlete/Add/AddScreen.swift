import PhotosUI
import SwiftUI

/// Add a recipe from one field: paste a link, describe a dish or what is in
/// the fridge, or add photos of a recipe. It ends on the saved recipe with
/// Add to list and Open, so the next step is one tap.
struct AddScreen: View {
    @Environment(RecipeIntake.self) private var intake
    @Environment(Library.self) private var library
    @Environment(AppNavigation.self) private var navigation

    @State private var picked: [PhotosPickerItem] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Paste a link, describe a dish, or add photos of a recipe.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                input
                if !intake.photos.isEmpty { photoStrip }
                controls
                if intake.photos.count > 1 {
                    Text("Several photos are read as one recipe, e.g. two pages of a cookbook.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                outcome
            }
            .padding(16)
        }
        .accessibilityIdentifier("add.form")
        .scrollDismissesKeyboard(.interactively)
        .contentMargins(.bottom, 72, for: .scrollContent)
        .background(Color(.systemGroupedBackground))
        .undoBanner(isCovered: navigation.immersive != nil)
        .navigationTitle("Add a recipe")
        .onChange(of: picked) {
            let items = picked
            guard !items.isEmpty else { return }
            picked = []
            Task {
                for item in items {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let jpeg = PhotoEncoder.jpeg(from: data)
                    else { continue }
                    intake.attach(RecipePhoto(id: UUID(), jpeg: jpeg))
                }
            }
        }
    }

    private var input: some View {
        TextField(
            "Recipe link or description", text: Binding(get: { intake.text }, set: { intake.edit($0) }),
            // Verbatim, or the example address is drawn as a link.
            prompt: Text(verbatim: "https://www.bbcgoodfood.com/recipes/…\nor: something warming with the leeks and potatoes I have"),
            axis: .vertical)
            .lineLimit(3...8)
            .textInputAutocapitalization(.never)
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .disabled(intake.isWorking || !intake.photos.isEmpty)
            .opacity(intake.photos.isEmpty ? 1 : 0.5)
            .accessibilityIdentifier("add.textField")
    }

    private var photoStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(Array(intake.photos.enumerated()), id: \.element.id) { index, photo in
                    Group {
                        if let image = UIImage(data: photo.jpeg) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Color(.tertiarySystemFill)
                        }
                    }
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Photo \(index + 1)")
                    .overlay(alignment: .topTrailing) {
                        Button("Remove photo \(index + 1)", systemImage: "xmark.circle.fill") {
                            intake.removePhoto(photo.id)
                        }
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.7))
                        .frame(width: 44, height: 44, alignment: .topTrailing)
                        .contentShape(Rectangle())
                        .disabled(intake.isWorking)
                        .accessibilityIdentifier("add.removePhoto.\(index)")
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            PhotosPicker(selection: $picked, maxSelectionCount: 6, matching: .images) {
                Label("Choose photos", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(.bordered)
            .disabled(intake.isWorking)
            .accessibilityIdentifier("add.choosePhotosButton")

            Button {
                intake.submit()
            } label: {
                HStack(spacing: 6) {
                    if intake.isWorking {
                        ProgressView()
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(intake.submitLabel)
                }
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!intake.canSubmit)
            .accessibilityIdentifier("add.submitButton")
        }
        .controlSize(.large)
    }

    @ViewBuilder private var outcome: some View {
        switch intake.phase {
        case .editing:
            EmptyView()
        case .working(let kind):
            WorkingLine(kind: kind)
        case .finished(.alreadySaved(let id)):
            notice(systemImage: "info.circle", tint: .secondary) {
                Text("You've already saved that one.")
                NavigationLink("Open it", value: Route.recipe(id))
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("add.openExistingLink")
            }
        case .finished(.failed(let failure)):
            notice(systemImage: "exclamationmark.circle", tint: .red) {
                Text(failure.message)
                    .accessibilityIdentifier("add.error")
            }
        case .finished(.saved(let recipe)):
            saved(recipe)
        }
    }

    private func saved(_ recipe: Recipe) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Saved to your recipes", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            HStack(spacing: 12) {
                AddToListButton(identifier: "add.addToList") {
                    await library.addMeal(recipe.id, title: recipe.title, to: $0)
                }
                NavigationLink("Open", value: Route.recipe(recipe.id))
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("add.openButton")
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(recipe.title)
                    .font(.title3.bold())
                RecipeMeta(recipe: recipe)
                ForEach(recipe.ingredientGroups) { group in
                    Text(group.heading ?? "Ingredients")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(group.lines) { line in
                        RecipeIngredientRow(ingredient: line.ingredient)
                    }
                }
                if !recipe.steps.isEmpty {
                    Text("Method")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                        RecipeStepRow(number: index + 1, text: step)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func notice(systemImage: String, tint: Color, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 6) { content() }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// What is happening while the request is out. The second line appears after
/// a moment so a long wait reads as progress; neither is reported by the server.
private struct WorkingLine: View {
    let kind: RecipeRequest.Kind

    @State private var isLater = false

    private var lines: (String, String) {
        switch kind {
        case .link: ("Reading the page…", "Sorting the ingredients…")
        case .describe: ("Writing the recipe…", "Matching ingredients…")
        case .photos: ("Reading your photos…", "Writing it up…")
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(isLater ? lines.1 : lines.0)
                .foregroundStyle(.secondary)
        }
        .task {
            try? await Task.sleep(for: .seconds(2.5))
            isLater = !Task.isCancelled
        }
    }
}
