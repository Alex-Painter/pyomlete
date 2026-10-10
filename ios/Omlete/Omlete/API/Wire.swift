import Foundation

/// The server's JSON, in and out. The DTOs are private to this file, so the
/// rest of the app can only name domain values.
nonisolated enum Wire {
    static func summaries(_ data: Data) throws -> [ListSummary] {
        try JSONDecoder().decode([SummaryDTO].self, from: data).map { dto in
            ListSummary(
                id: ListID(dto.id), name: dto.name, itemCount: dto.item_count, checkedCount: dto.checked_count,
                meals: dto.recipes.map { ListSummary.Meal(id: RecipeID($0.id), title: $0.title) })
        }
    }

    static func createdList(_ data: Data) throws -> ListSummary {
        let dto = try JSONDecoder().decode(CreatedListDTO.self, from: data)
        return ListSummary(id: ListID(dto.id), name: dto.name, itemCount: 0, checkedCount: 0, meals: [])
    }

    static func detail(_ data: Data) throws -> ListDetail {
        let dto = try JSONDecoder().decode(DetailDTO.self, from: data)
        let items = dto.items.map { item in
            ListItem(
                id: ItemID(item.id), name: item.name, amount: item.amount, unit: item.unit,
                category: item.category ?? ListLayout.fallbackAisle, checked: item.checked ?? false,
                sources: (item.sources ?? []).map { source in
                    ItemSource(recipeID: source.recipe_id.map { RecipeID($0) }, amount: source.amount)
                })
        }
        return ListDetail(id: ListID(dto.id), name: dto.name, recipes: dto.recipes.map { RecipeID($0) }, items: items)
    }

    static func aisleOrder(_ data: Data) throws -> [String] {
        try JSONDecoder().decode([CategoryDTO].self, from: data).sorted { $0.order < $1.order }.map(\.name)
    }

    static func category(_ data: Data) throws -> String {
        try JSONDecoder().decode(CategorizedDTO.self, from: data).category
    }

    static func units(_ data: Data) throws -> [String] {
        try JSONDecoder().decode([String].self, from: data)
    }

    static func recipes(_ data: Data) throws -> [RecipeSummary] {
        try JSONDecoder().decode([RecipeDTO].self, from: data).map {
            RecipeSummary(
                id: RecipeID($0.id), title: $0.title, imageURL: $0.image_url.flatMap(URL.init(string:)),
                totalMinutes: $0.total_minutes)
        }
    }

    static func recipe(_ data: Data) throws -> Recipe {
        let dto = try JSONDecoder().decode(RecipeDetailDTO.self, from: data)
        return Recipe(
            id: RecipeID(dto._id), title: dto.title, steps: dto.instructions ?? [],
            ingredients: (dto.ingredients ?? []).map {
                Recipe.Ingredient(name: $0.name, amount: $0.amount, unit: $0.unit, note: $0.note)
            },
            baseServings: dto.servings.flatMap { $0 > 0 ? $0 : nil }, rating: dto.rating)
    }

    /// `checked` is left out on purpose: POST items ignores it.
    static func newItem(_ item: ListItem) throws(APIError) -> Data {
        try encode(NewItemDTO(id: item.id.rawValue, name: item.name, amount: item.amount, unit: item.unit, category: item.category))
    }

    static func reorder(category: String, itemIDs: [ItemID]) throws(APIError) -> Data {
        try encode(ReorderDTO(category: category, item_ids: itemIDs.map(\.rawValue)))
    }

    /// A body that cannot be encoded (a non-finite amount) is a request the
    /// server could never accept, so it is rejected here and the op is dropped.
    static func encode(_ value: some Encodable) throws(APIError) -> Data {
        do { return try JSONEncoder().encode(value) } catch { throw .rejected(400) }
    }
}

nonisolated private struct SummaryDTO: Decodable {
    struct Meal: Decodable {
        let id: String
        let title: String
    }

    let id: String
    let name: String
    let item_count: Int
    let checked_count: Int
    let recipes: [Meal]
}

nonisolated private struct CreatedListDTO: Decodable {
    let id: String
    let name: String
}

nonisolated private struct DetailDTO: Decodable {
    struct Item: Decodable {
        let id: String
        let name: String
        let amount: Double?
        let unit: String?
        let category: String?
        let checked: Bool?
        let sources: [Source]?
    }

    struct Source: Decodable {
        let recipe_id: String?
        let amount: Double?
    }

    let id: String
    let name: String
    let recipes: [String]
    let items: [Item]
}

nonisolated private struct CategoryDTO: Decodable {
    let name: String
    let order: Int
}

nonisolated private struct CategorizedDTO: Decodable {
    let category: String
}

nonisolated private struct RecipeDTO: Decodable {
    let id: String
    let title: String
    let image_url: String?
    let total_minutes: Int?
}

/// The single-recipe endpoint returns the Mongo document, so its id is `_id`.
nonisolated private struct RecipeDetailDTO: Decodable {
    struct Ingredient: Decodable {
        let name: String
        let amount: Double?
        let unit: String?
        let note: String?
    }

    let _id: String
    let title: String
    let instructions: [String]?
    let ingredients: [Ingredient]?
    let servings: Int?
    let rating: Int?
}

nonisolated private struct NewItemDTO: Encodable {
    let id: String
    let name: String
    let amount: Double?
    let unit: String?
    let category: String
}

nonisolated private struct ReorderDTO: Encodable {
    let category: String
    let item_ids: [String]
}
