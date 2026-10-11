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
                totalMinutes: $0.total_minutes, rating: $0.rating, sourceName: $0.source_name,
                ingredientCount: $0.ingredient_count)
        }
    }

    static func recipe(_ data: Data) throws -> Recipe {
        try JSONDecoder().decode(RecipeDetailDTO.self, from: data).recipe()
    }

    /// The body of the PUT that replaces a recipe's title, method and
    /// ingredients. The server requires a unit to be a string, so none goes as
    /// "". An aisle or a quantity that is not set is left out, which the
    /// server reads as its fallback aisle and as null.
    static func recipeUpdate(_ edit: RecipeEdit) throws(APIError) -> Data {
        try encode(RecipeUpdateDTO(
            title: edit.title, instructions: edit.steps,
            ingredients: edit.ingredients.map {
                RecipeUpdateDTO.Ingredient(
                    name: $0.name, unit: $0.unit ?? "", amount: $0.amount, note: $0.note, group: $0.group,
                    category: $0.category, excluded_from_list: !$0.isOnList)
            }))
    }

    /// A link or a description answers with one recipe; photos answer with a list, of which the first is ours.
    static func createdRecipe(_ data: Data) throws -> Recipe {
        if let one = try? JSONDecoder().decode(RecipeDetailDTO.self, from: data) { return try one.recipe() }
        guard let first = try JSONDecoder().decode([RecipeDetailDTO].self, from: data).first else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "no recipe"))
        }
        return try first.recipe()
    }

    /// The body of the 409 that import answers when the page is already a recipe.
    static func alreadyImported(_ data: Data) -> RecipeID? {
        (try? JSONDecoder().decode(AlreadyImportedDTO.self, from: data))?.detail.recipe_id.map { RecipeID($0) }
    }

    /// Cards hidden by "Not for me" or Clear are dropped here, so those two
    /// states never reach the app. A card saved without a recipe can only be saved again.
    static func suggestions(_ data: Data) throws -> [Suggestion] {
        try JSONDecoder().decode([SuggestionDTO].self, from: data).compactMap { dto in
            let stage: Suggestion.Stage
            switch (dto.status, dto.recipe_id) {
            case ("dismissed", _), ("cleared", _): return nil
            case ("saved", let recipe?): stage = .saved(RecipeID(recipe))
            case ("saving", _): stage = .saving
            case ("failed", _): stage = .failed
            default: stage = .fresh
            }
            return Suggestion(
                id: SuggestionID(dto.id), title: dto.title, reason: dto.reason,
                imageURL: dto.image_url.flatMap(URL.init(string:)), source: source(dto.source_name, dto.source_url),
                totalMinutes: dto.total_minutes, section: DiscoverSection(named: dto.section), stage: stage)
        }
    }

    static func tune(_ tune: TuneSettings) throws(APIError) -> Data {
        try encode(TuneDTO(diet: tune.diet.rawValue, ease: tune.effort.rawValue, notes: tune.notes))
    }

    static func saveSuggestion(onto list: ListID?) throws(APIError) -> Data {
        try encode(SaveSuggestionDTO(list_id: list?.rawValue))
    }

    static func dismissal() throws(APIError) -> Data {
        try encode(["status": "dismissed"])
    }

    static func clearing(_ ids: [SuggestionID]) throws(APIError) -> Data {
        try encode(["ids": ids.map(\.rawValue)])
    }

    struct Upload {
        let path: String
        let body: Data
        let contentType: String
    }

    static func creation(_ request: RecipeRequest) throws(APIError) -> Upload {
        switch request {
        case .link(let url):
            return Upload(path: "recipes/import-from-url/", body: try encode(["url": url]), contentType: json)
        case .describe(let prompt):
            return Upload(path: "recipes/generate/", body: try encode(["prompt": prompt]), contentType: json)
        case .photos(let photos):
            let boundary = "omlete-\(UUID().uuidString)"
            var body = Data()
            for (index, photo) in photos.enumerated() {
                body.append(Data([
                    "--\(boundary)",
                    #"Content-Disposition: form-data; name="files"; filename="photo-\#(index + 1).jpg""#,
                    "Content-Type: image/jpeg", "", "",
                ].joined(separator: "\r\n").utf8))
                body.append(photo.jpeg)
                body.append(Data("\r\n".utf8))
            }
            // One group holding every photo: they are pages of the same recipe.
            body.append(Data([
                "--\(boundary)", #"Content-Disposition: form-data; name="group_sizes""#, "", "\(photos.count)",
                "--\(boundary)--", "",
            ].joined(separator: "\r\n").utf8))
            return Upload(
                path: "recipes/extract-from-images/", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        }
    }

    static let json = "application/json"

    fileprivate static func source(_ name: String?, _ url: String?) -> RecipeSource? {
        // Cards come from any producer, so only a web page is ever made tappable.
        let url = url.flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? $0 : nil }
        guard name != nil || url != nil else { return nil }
        return RecipeSource(name: name ?? "Source", url: url)
    }

    /// The server writes times with or without fractions of a second, and without a zone when it means UTC.
    fileprivate static func date(_ text: String?) -> Date? {
        guard var text else { return nil }
        let time = text.drop { $0 != "T" }
        if !time.contains(where: { "Z+-".contains($0) }) { text += "Z" }
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return (try? fractional.parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text))
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
    let rating: Int?
    let source_name: String?
    let ingredient_count: Int?
}

/// A whole recipe is the Mongo document, so its id is `_id`.
nonisolated private struct RecipeDetailDTO: Decodable {
    struct Ingredient: Decodable {
        let name: String
        let amount: Double?
        let unit: String?
        let note: String?
        let group: String?
        let category: String?
        let excluded_from_list: Bool?
    }

    let _id: String
    let title: String
    let instructions: [String]?
    let ingredients: [Ingredient]?
    let servings: Int?
    let rating: Int?
    let image_url: String?
    let total_minutes: Int?
    let cook_minutes: Int?
    let source_url: String?
    let source_name: String?
    let created_at: String?

    func recipe() throws -> Recipe {
        Recipe(
            id: RecipeID(_id), title: title, steps: instructions ?? [],
            ingredients: (ingredients ?? []).map {
                Recipe.Ingredient(
                    name: $0.name, amount: $0.amount, unit: $0.unit, note: $0.note, group: $0.group,
                    category: $0.category, isOnList: !($0.excluded_from_list ?? false))
            },
            baseServings: servings.flatMap { $0 > 0 ? $0 : nil }, rating: rating,
            imageURL: image_url.flatMap(URL.init(string:)), totalMinutes: total_minutes ?? cook_minutes,
            source: Wire.source(source_name, source_url), createdAt: Wire.date(created_at))
    }
}

nonisolated private struct RecipeUpdateDTO: Encodable {
    struct Ingredient: Encodable {
        let name: String
        let unit: String
        let amount: Double?
        let note: String?
        let group: String?
        let category: String?
        let excluded_from_list: Bool
    }

    let title: String
    let instructions: [String]
    let ingredients: [Ingredient]
}

nonisolated private struct AlreadyImportedDTO: Decodable {
    struct Detail: Decodable {
        let recipe_id: String?
    }

    let detail: Detail
}

nonisolated private struct SuggestionDTO: Decodable {
    let id: String
    let title: String
    let reason: String?
    let image_url: String?
    let source_url: String?
    let source_name: String?
    let total_minutes: Int?
    let section: String?
    let status: String
    let recipe_id: String?
}

nonisolated private struct TuneDTO: Encodable {
    let diet: String
    let ease: String
    let notes: String
}

nonisolated private struct SaveSuggestionDTO: Encodable {
    let list_id: String?
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
