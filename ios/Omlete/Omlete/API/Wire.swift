import Foundation

/// The server's JSON, in and out. The DTOs are private to this file, so the
/// rest of the app can only name domain values.
nonisolated enum Wire {
    static func summaries(_ data: Data) throws -> [ListSummary] {
        try JSONDecoder().decode([SummaryDTO].self, from: data).map { dto throws in
            ListSummary(
                id: ListID(dto.id), name: dto.name, itemCount: dto.item_count, checkedCount: dto.checked_count,
                meals: dto.recipes.map { ListSummary.Meal(id: RecipeID($0.id), title: $0.title) },
                weekStart: try planDate(dto.week_start))
        }
    }

    static func createdList(_ data: Data) throws -> ListSummary {
        let dto = try JSONDecoder().decode(CreatedListDTO.self, from: data)
        return ListSummary(
            id: ListID(dto.id), name: dto.name, itemCount: 0, checkedCount: 0, meals: [],
            weekStart: try planDate(dto.week_start))
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
        return ListDetail(
            id: ListID(dto.id), name: dto.name, recipes: dto.recipes.map { RecipeID($0) }, items: items,
            weekStart: try planDate(dto.week_start), days: try (dto.days ?? []).map(day))
    }

    /// A meal wins over Out, as the server keeps it, so the two never arrive together.
    private static func day(_ dto: DayDTO) throws -> PlanDay {
        let plan: DayPlan = if let recipe = dto.recipe_id { .meal(RecipeID(recipe)) } else if dto.status == "out" { .out } else { .open }
        return PlanDay(date: try planDate(dto.date), plan: plan)
    }

    private static func planDate(_ text: String) throws -> PlanDate {
        guard let date = PlanDate(iso: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not a date: \(text)"))
        }
        return date
    }

    private static func planDate(_ text: String?) throws -> PlanDate? {
        try text.map(planDate)
    }

    static func dayUpdate(_ plan: DayPlan) throws(APIError) -> Data {
        switch plan {
        case .meal(let recipe): try encode(DayUpdateDTO(recipe_id: recipe.rawValue, status: "open"))
        case .open: try encode(DayUpdateDTO(recipe_id: nil, status: "open"))
        case .out: try encode(DayUpdateDTO(recipe_id: nil, status: "out"))
        }
    }

    static func aisleOrder(_ data: Data) throws -> AisleOrder {
        AisleOrder(try JSONDecoder().decode([CategoryDTO].self, from: data).sorted { $0.order < $1.order }.map(\.name))
    }

    /// The whole list, each aisle numbered by its place: the PUT replaces every aisle the server has.
    static func aisleOrderBody(_ order: AisleOrder) throws(APIError) -> Data {
        try encode(CategoriesDTO(categories: order.names.enumerated().map { CategoryDTO(name: $1, order: $0) }))
    }

    static func weekStartWeekday(_ data: Data) throws -> Int {
        let weekday = try JSONDecoder().decode(PlanSettingsDTO.self, from: data).week_start_weekday
        guard (0...6).contains(weekday) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not a weekday: \(weekday)"))
        }
        return weekday
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
                ingredientCount: $0.ingredient_count, lastPlannedOn: try planDate($0.last_planned_on),
                ingredientNames: $0.ingredient_names ?? [], cuisine: $0.cuisine, createdAt: date($0.created_at))
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

    /// How the server says a job stands. A saved job names its recipe and does not carry it.
    enum JobAnswer: Equatable {
        case working
        case saved(RecipeID)
        case alreadySaved(RecipeID)
        case failed(RecipeCreation.Failure)
    }

    /// A status this build does not know, or one missing the recipe it promises, throws.
    /// A failure it does not know is still a failure.
    static func jobAnswer(_ data: Data) throws -> JobAnswer {
        let dto = try JSONDecoder().decode(RecipeJobDTO.self, from: data)
        switch (dto.status, dto.recipe_id) {
        case ("working", _): return .working
        case ("saved", let recipe?): return .saved(RecipeID(recipe))
        case ("already_imported", let recipe?): return .alreadySaved(RecipeID(recipe))
        case ("failed", _):
            switch dto.failure {
            case "link_blocked": return .failed(.linkBlocked)
            case "no_recipe_on_page": return .failed(.noRecipeOnPage)
            case "site_did_not_respond": return .failed(.siteDidNotRespond)
            default: return .failed(.other)
            }
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "job status \(dto.status)"))
        }
    }

    /// Cards hidden by "Not for me" or Clear are dropped here, so those two
    /// states never reach the app. A card saved without a recipe has been
    /// answered and has nothing to open, so it reads as failed: Discover's to
    /// show, with Try again, and never one of Home's picks. A status the app
    /// does not know is dropped: it could not say what the card's buttons would do.
    static func suggestions(_ data: Data) throws -> [Suggestion] {
        try JSONDecoder().decode([SuggestionDTO].self, from: data).compactMap { dto in
            let stage: Suggestion.Stage
            switch (dto.status, dto.recipe_id) {
            case ("dismissed", _), ("cleared", _): return nil
            case ("saved", let recipe?): stage = .saved(RecipeID(recipe))
            case ("saved", nil), ("failed", _): stage = .failed
            case ("saving", _): stage = .saving
            case ("new", _): stage = .fresh
            default: return nil
            }
            return Suggestion(
                id: SuggestionID(dto.id), title: dto.title, reason: dto.reason,
                imageURL: dto.image_url.flatMap(URL.init(string:)), source: source(dto.source_name, dto.source_url),
                totalMinutes: dto.total_minutes, section: DiscoverSection(named: dto.section), stage: stage)
        }
    }

    /// `null` when no plan is waiting.
    static func waitingWeek(_ data: Data) throws -> WeekPlan? {
        try JSONDecoder().decode(WeekPlanDTO?.self, from: data).map(week)
    }

    static func week(_ data: Data) throws -> WeekPlan {
        try week(JSONDecoder().decode(WeekPlanDTO.self, from: data))
    }

    private static func week(_ dto: WeekPlanDTO) throws -> WeekPlan {
        WeekPlan(
            id: WeekPlanID(dto.id), weekOf: try planDate(dto.week_of), note: dto.note,
            meals: try dto.meals.map { meal in
                WeekMeal(
                    day: try planDate(meal.day), title: meal.title, reason: meal.reason,
                    recipe: meal.recipe_id.map { RecipeID($0) }, imageURL: meal.image_url.flatMap(URL.init(string:)))
            }.sorted { $0.day < $1.day })
    }

    static func madeWeek(_ data: Data) throws -> MadeWeek {
        let dto = try JSONDecoder().decode(MadeWeekDTO.self, from: data)
        return MadeWeek(list: ListID(dto.list_id), name: dto.name, undo: ChefActionID(dto.undo))
    }

    /// A stance or source this build does not know is dropped, as an unknown
    /// card status is: the row could not say what Chef does with it. Forgotten
    /// ones are not listed by the server, and are dropped if one ever is.
    static func preferences(_ data: Data) throws -> [Preference] {
        try JSONDecoder().decode([PreferenceDTO].self, from: data).compactMap { dto in
            guard !dto.forgotten, let stance = Stance(rawValue: dto.stance),
                  let source = Preference.Source(rawValue: dto.source) else { return nil }
            return Preference(
                id: PreferenceID(dto.id), subject: dto.subject, stance: stance, evidence: dto.evidence, source: source)
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

    /// `onlyNew` is left out when false, which is the request older servers and the web know.
    static func clearing(_ ids: [SuggestionID], onlyNew: Bool) throws(APIError) -> Data {
        try encode(ClearSuggestionsDTO(ids: ids.map(\.rawValue), only_new: onlyNew ? true : nil))
    }

    struct Upload {
        let path: String
        let body: Data
        let contentType: String
    }

    /// The request that starts a job for each kind of recipe request.
    static func jobStart(_ request: RecipeRequest, key: RecipeJobID) throws(APIError) -> Upload {
        let path = "recipe-jobs/\(key.rawValue)/\(request.kind.rawValue)"
        switch request {
        case .link(let url):
            return Upload(path: path, body: try encode(["url": url]), contentType: json)
        case .describe(let prompt):
            return Upload(path: path, body: try encode(["prompt": prompt]), contentType: json)
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
            // The server reads every photo of a job as pages of one recipe.
            body.append(Data("--\(boundary)--\r\n".utf8))
            return Upload(path: path, body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        }
    }

    static let json = "application/json"

    /// The AI SDK's chat request plus `page`, as the web's `askChef` sends it.
    /// Web searches and tools that did not finish are left out: the search
    /// results belong to Anthropic's side of the turn.
    static func chefChat(_ chat: String, messages: [ChefMessage], page: ChefPage) throws(APIError) -> Data {
        let messages = messages.map { message -> JSONValue in
            let parts = message.parts.compactMap { part -> JSONValue? in
                switch part {
                case .text(let text):
                    return text.isEmpty ? nil : .object(["type": "text", "text": .string(text)])
                case .photo(let photo):
                    return .object([
                        "type": "file", "mediaType": "image/jpeg",
                        "url": .string("data:image/jpeg;base64,\(photo.jpeg.base64EncodedString())"),
                    ])
                case .tool(let tool):
                    guard !tool.providerExecuted, case .done(let output) = tool.state else { return nil }
                    return .object([
                        "type": .string("tool-\(tool.name)"), "toolCallId": .string(tool.callID),
                        "state": "output-available", "input": tool.input ?? .object([:]), "output": output,
                    ])
                }
            }
            return .object(["id": .string(message.id), "role": .string(message.role.rawValue), "parts": .array(parts)])
        }
        return try encode(JSONValue.object([
            "trigger": "submit-message", "id": .string(chat), "messages": .array(messages),
            "page": .object(["path": .string(page.path)]),
        ]))
    }

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
    let week_start: String?
}

nonisolated private struct CreatedListDTO: Decodable {
    let id: String
    let name: String
    let week_start: String?
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
    let week_start: String?
    let days: [DayDTO]?
}

nonisolated private struct DayDTO: Decodable {
    let date: String
    let recipe_id: String?
    let status: String?
}

/// `recipe_id` goes as null to clear a day, so it is written out even when nil.
nonisolated private struct DayUpdateDTO: Encodable {
    let recipe_id: String?
    let status: String

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recipe_id, forKey: .recipe_id)
        try container.encode(status, forKey: .status)
    }

    private enum CodingKeys: CodingKey {
        case recipe_id, status
    }
}

nonisolated private struct CategoriesDTO: Encodable {
    let categories: [CategoryDTO]
}

nonisolated private struct CategoryDTO: Codable {
    let name: String
    let order: Int
}

nonisolated private struct PlanSettingsDTO: Decodable {
    let week_start_weekday: Int
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
    let last_planned_on: String?
    let ingredient_names: [String]?
    let cuisine: String?
    let created_at: String?
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

nonisolated private struct RecipeJobDTO: Decodable {
    let status: String
    let recipe_id: String?
    let failure: String?
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

nonisolated private struct WeekPlanDTO: Decodable {
    struct Meal: Decodable {
        let day: String
        let title: String
        let reason: String
        let recipe_id: String?
        let image_url: String?
    }

    let id: String
    let week_of: String
    let note: String
    let meals: [Meal]
}

nonisolated private struct MadeWeekDTO: Decodable {
    let list_id: String
    let name: String
    let undo: String
}

nonisolated private struct PreferenceDTO: Decodable {
    let id: String
    let subject: String
    let stance: String
    let evidence: String
    let source: String
    let forgotten: Bool
}

nonisolated private struct TuneDTO: Encodable {
    let diet: String
    let ease: String
    let notes: String
}

nonisolated private struct SaveSuggestionDTO: Encodable {
    let list_id: String?
}

nonisolated private struct ClearSuggestionsDTO: Encodable {
    let ids: [String]
    let only_new: Bool?
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
