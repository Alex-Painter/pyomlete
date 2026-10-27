import SwiftUI

/// On the last page of a cook opened from a list: the meal's tick there,
/// which Finish has just set, so a Finish tapped to look ahead is one tap to take back.
struct CookedOnList: View {
    let store: ListStore
    let recipe: RecipeID
    let title: String

    var body: some View {
        VStack(spacing: 0) {
            if case .ready(let list) = store.phase, list.recipes.contains(recipe) {
                HStack(spacing: 12) {
                    Text("On \(list.name)")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    CookedToggle(cooked: list.cooked.contains(recipe), title: title, identifier: "cook.cookedToggle") {
                        store.setCooked(recipe, $0)
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .task { await store.refresh() }
    }
}
