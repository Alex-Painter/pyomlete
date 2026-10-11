import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Omlete

/// The server's JSON for Explore, read through the real client.
@MainActor struct ExploreAPITests {
    private typealias Call = ScriptedTransport.Call
    private let transport = ScriptedTransport()

    private var api: APIClient {
        APIClient(baseURL: URL(string: "http://phone.test")!, transport: transport)
    }

    private func serverAnswers(_ status: Int, _ body: String = "{}") {
        transport.reply = { _ in .status(status, body) }
    }

    static let traybakeJSON = """
        {"_id":"traybake","title":"Traybake","created_at":"2026-10-10T09:00:00.123000","servings":4,"rating":5,
         "image_url":null,"total_minutes":null,"cook_minutes":45,
         "source_url":"https://example.com/traybake","source_name":"example.com",
         "instructions":["Roast.","Dress."],
         "ingredients":[
          {"name":"chicken","amount":6,"unit":"whole","note":null,"group":"For the traybake","category":"Meat & Fish","excluded_from_list":false},
          {"name":"potatoes","amount":500,"unit":"g","note":"halved","group":"For the traybake","category":"Fresh Produce","excluded_from_list":false},
          {"name":"oil","amount":2,"unit":"tbsp","note":null,"group":"For the dressing","category":"Pantry","excluded_from_list":true},
          {"name":"salt","amount":null,"unit":"to taste"}]}
        """

    @Test func aRecipeCarriesItsSourceTimeGroupsAndShoppingFlags() async throws {
        serverAnswers(200, Self.traybakeJSON)

        let recipe = try await api.recipe("traybake")

        #expect(recipe.source == RecipeSource(name: "example.com", url: URL(string: "https://example.com/traybake")))
        #expect(recipe.totalMinutes == 45)
        #expect(recipe.imageURL == nil)
        #expect(recipe.ingredients.map(\.isOnList) == [true, true, false, true])
        #expect(recipe.ingredients.map(\.category) == ["Meat & Fish", "Fresh Produce", "Pantry", nil])
        #expect(recipe.ingredientGroups.map(\.heading) == ["For the traybake", "For the dressing", nil])
        #expect(recipe.ingredientGroups.map { $0.lines.map(\.id) } == [[0, 1], [2], [3]])
        let added = try #require(recipe.createdAt)
        #expect(abs(added.timeIntervalSince(try Date("2026-10-10T09:00:00Z", strategy: .iso8601)) - 0.123) < 0.001)
    }

    @Test(arguments: ["2026-10-10T09:00:00", "2026-10-10T09:00:00Z", "2026-10-10T09:00:00+00:00", "2026-10-10T10:00:00.5+01:00"])
    func theDateARecipeWasAddedIsReadHoweverTheServerWritesIt(written: String) async throws {
        serverAnswers(200, #"{"_id":"r","title":"R","created_at":"\#(written)"}"#)

        let added = try #require(try await api.recipe("r").createdAt)

        #expect(abs(added.timeIntervalSince(try Date("2026-10-10T09:00:00Z", strategy: .iso8601))) < 1)
    }

    @Test func recipeSummariesCarryRatingAndSource() async throws {
        serverAnswers(200, #"[{"id":"a","title":"A","rating":4,"total_minutes":20,"source_name":"example.com","image_url":null}]"#)

        #expect(try await api.recipes() == [
            RecipeSummary(id: "a", title: "A", totalMinutes: 20, rating: 4, sourceName: "example.com"),
        ])
    }

    @Test func hiddenCardsNeverLeaveTheBoundaryAndEveryOtherStatusBecomesAStage() async throws {
        serverAnswers(200, """
            [{"id":"1","title":"New","status":"new","section":"For this week","reason":"Because","total_minutes":20,
              "source_url":"https://example.com/x","source_name":null,"image_url":"https://img.test/1.jpg","recipe_id":null},
             {"id":"2","title":"Saving","status":"saving","section":"Under 30 minutes","source_name":"Chef"},
             {"id":"3","title":"Saved","status":"saved","recipe_id":"r3","section":"Something new"},
             {"id":"4","title":"Failed","status":"failed","section":"Weekend project"},
             {"id":"5","title":"Dismissed","status":"dismissed"},
             {"id":"6","title":"Cleared","status":"cleared"},
             {"id":"7","title":"Saved with no recipe","status":"saved"},
             {"id":"8","title":"From the future","status":"simmering"}]
            """)

        let cards = try await api.suggestions()

        #expect(cards.map(\.id) == ["1", "2", "3", "4", "7", "8"])
        #expect(cards.map(\.stage) == [.fresh, .saving, .saved("r3"), .failed, .fresh, .fresh])
        #expect(cards.map(\.section) == [.thisWeek, .under30, .somethingNew, .moreIdeas, .moreIdeas, .moreIdeas])
        #expect(cards[0].source == RecipeSource(name: "Source", url: URL(string: "https://example.com/x")))
        #expect(cards[1].source == RecipeSource(name: "Chef", url: nil))
        #expect(cards[2].source == nil)
        #expect(cards[0].imageURL == URL(string: "https://img.test/1.jpg"))
    }

    @Test func aLinkAlreadyImportedIsAnOutcomeCarryingItsRecipe() async {
        serverAnswers(409, #"{"detail":{"message":"That page has already been imported.","recipe_id":"traybake"}}"#)

        #expect(await api.createRecipe(.link("https://example.com/traybake")) == .alreadySaved("traybake"))
        #expect(transport.calls == [Call(method: "POST", path: "/api/recipes/import-from-url/")])
        #expect(transport.bodies[0] as? [String: String] == ["url": "https://example.com/traybake"])
    }

    @Test(arguments: [
        (400, RecipeCreation.Failure.linkBlocked), (404, .noRecipeOnPage), (502, .siteDidNotRespond), (500, .other), (422, .other),
    ])
    func aLinkThatFailsSaysWhy(status: Int, expected: RecipeCreation.Failure) async {
        serverAnswers(status, #"{"detail":"no"}"#)

        #expect(await api.createRecipe(.link("https://example.com/x")) == .failed(expected))
    }

    @Test(arguments: [400, 404, 409, 500, 502])
    func aDescriptionThatFailsOnlyEverSaysSomethingWentWrong(status: Int) async {
        serverAnswers(status, #"{"detail":{"recipe_id":"x"}}"#)

        #expect(await api.createRecipe(.describe("leek and potato soup")) == .failed(.other))
    }

    @Test func aCreateThatWasSentAndNeverAnsweredIsNotCalledUnreachable() async {
        transport.reply = { _ in .timedOut }

        #expect(await api.createRecipe(.describe("leek and potato soup")) == .failed(.noAnswer))
    }

    @Test func aSourceThatIsNotAWebPageKeepsItsNameAndLosesItsLink() async throws {
        serverAnswers(200, #"[{"id":"1","title":"Odd","status":"new","source_url":"tel:0123456789","source_name":"Somewhere"}]"#)

        #expect(try await api.suggestions().first?.source == RecipeSource(name: "Somewhere", url: nil))
    }

    @Test func creatingWithNoSignalSaysSo() async {
        transport.reply = { _ in .unreachable }

        #expect(await api.createRecipe(.describe("leek and potato soup")) == .failed(.unreachable))
    }

    @Test func aDescriptionIsSentAsAPromptAndAnswersWithTheRecipe() async {
        serverAnswers(200, Self.traybakeJSON)

        guard case .saved(let recipe) = await api.createRecipe(.describe("a traybake")) else {
            Issue.record("not saved")
            return
        }
        #expect(recipe.id == "traybake")
        #expect(transport.calls == [Call(method: "POST", path: "/api/recipes/generate/")])
        #expect(transport.bodies[0] as? [String: String] == ["prompt": "a traybake"])
    }

    @Test func photosAreUploadedAsOneGroupAndTheFirstRecipeBackIsTheResult() async throws {
        serverAnswers(200, "[\(Self.traybakeJSON)]")
        let photos = [RecipePhoto(id: UUID(), jpeg: Data("first".utf8)), RecipePhoto(id: UUID(), jpeg: Data("second".utf8))]

        guard case .saved(let recipe) = await api.createRecipe(.photos(photos)) else {
            Issue.record("not saved")
            return
        }

        #expect(recipe.title == "Traybake")
        let request = try #require(transport.requests.first)
        #expect(request.url?.path() == "/api/recipes/extract-from-images/")
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        let boundary = try #require(contentType.split(separator: "boundary=").last)
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body == [
            "--\(boundary)", #"Content-Disposition: form-data; name="files"; filename="photo-1.jpg""#,
            "Content-Type: image/jpeg", "", "first",
            "--\(boundary)", #"Content-Disposition: form-data; name="files"; filename="photo-2.jpg""#,
            "Content-Type: image/jpeg", "", "second",
            "--\(boundary)", #"Content-Disposition: form-data; name="group_sizes""#, "", "2",
            "--\(boundary)--", "",
        ].joined(separator: "\r\n"))
    }

    @Test func photosThatHoldNoRecipeFail() async {
        serverAnswers(200, "[]")

        #expect(await api.createRecipe(.photos([RecipePhoto(id: UUID(), jpeg: Data())])) == .failed(.other))
    }

    @Test func onlyTheCallsThatWaitOnAModelAreGivenLonger() async throws {
        serverAnswers(200, "[]")

        _ = try await api.lists()
        _ = try await api.suggestions()
        try await api.findIdeas(TuneSettings())
        _ = await api.createRecipe(.describe("soup of the day"))
        _ = await api.createRecipe(.link("https://example.com/x"))
        _ = await api.createRecipe(.photos([RecipePhoto(id: UUID(), jpeg: Data())]))

        let standard = URLRequest(url: URL(string: "http://phone.test")!).timeoutInterval
        #expect(transport.requests.map(\.timeoutInterval) == [standard, standard, 180, 180, 180, 180])
    }

    @Test func tuneSettingsAreSentUnderTheServersNames() async throws {
        try await api.findIdeas(TuneSettings(diet: .vegan, effort: .quick, notes: "use up spinach"))

        #expect(transport.calls == [Call(method: "POST", path: "/api/suggestions/refresh")])
        #expect(transport.bodies[0] as? [String: String] == ["diet": "vegan", "ease": "quick", "notes": "use up spinach"])
    }

    @Test func aRecipeAlreadyOnTheListIsAnOutcomeAndAnyOtherRefusalIsAnError() async throws {
        serverAnswers(400, #"{"detail":"Recipe already on this list"}"#)
        #expect(try await api.addRecipe("curry", to: "list") == .alreadyOnList)

        serverAnswers(200)
        #expect(try await api.addRecipe("curry", to: "list") == .added)

        serverAnswers(404)
        await #expect(throws: APIError.rejected(404)) { try await api.addRecipe("curry", to: "list") }
    }

    @Test func anIngredientIsKeptOffListsByItsPosition() async throws {
        try await api.setOnList("curry", ingredient: 2, false)

        #expect(transport.calls == [Call(method: "PATCH", path: "/api/recipes/curry/ingredients/2/exclude")])
        #expect(transport.bodies[0] as? [String: Bool] == ["excluded": true])
    }
}

struct ExploreModelTests {
    @Test func cardsAreShelvedInSectionOrderKeepingFeedOrderWithin() {
        func card(_ id: SuggestionID, _ section: DiscoverSection) -> Suggestion {
            Suggestion(id: id, title: id.rawValue, section: section, stage: .fresh)
        }
        let cards = [card("a", .moreIdeas), card("b", .somethingNew), card("c", .thisWeek), card("d", .somethingNew)]

        let shelves = Shelf.shelves(of: cards)

        #expect(shelves.map(\.section.title) == ["For this week", "Something new", "More ideas"])
        #expect(shelves.map { $0.cards.map(\.id) } == [["c"], ["b", "d"], ["a"]])
        #expect(Shelf.shelves(of: []).isEmpty)
    }

    @Test(arguments: [(5, "5 min"), (59, "59 min"), (60, "1 hr"), (95, "1 hr 35 min"), (180, "3 hr")])
    func minutesReadAsHoursOnceThereIsOne(minutes: Int, expected: String) {
        #expect(formatMinutes(minutes) == expected)
    }

    @Test func ingredientsWithNoHeadingsAreOneGroup() {
        let groups = Recipe.fixture().ingredientGroups

        #expect(groups.map(\.heading) == [nil])
        #expect(groups[0].lines.map(\.ingredient.name) == ["onions", "rice", "coconut milk"])
        #expect(Recipe(id: "x", title: "X", steps: [], ingredients: []).ingredientGroups.isEmpty)
    }

    @Test func aHeadingThatComesBackStartsANewGroup() {
        func ingredient(_ name: String, _ group: String?) -> Recipe.Ingredient {
            Recipe.Ingredient(name: name, group: group)
        }
        let recipe = Recipe(id: "x", title: "X", steps: [], ingredients: [
            ingredient("a", "Sauce"), ingredient("b", nil), ingredient("c", "Sauce"),
        ])

        #expect(recipe.ingredientGroups.map(\.heading) == ["Sauce", nil, "Sauce"])
        #expect(recipe.ingredientGroups.map(\.id) == [0, 1, 2])
    }

    @Test(arguments: [
        ("https://www.bbcgoodfood.com/recipes/x", RecipeRequest.Kind.link), ("  http://a.b  ", .link),
        ("https://nodot", .describe), ("see https://a.b/c for it", .describe), ("HTTPS://A.B", .describe),
        ("leeks and potatoes", .describe), ("egg", .describe),
    ])
    func oneWebAddressIsALinkAndAnythingElseIsADescription(text: String, expected: RecipeRequest.Kind) {
        #expect(RecipeRequest(text: text, photos: [])?.kind == expected)
    }

    @Test func thereIsNothingToSendUntilThreeCharactersOrAPhoto() {
        let photo = RecipePhoto(id: UUID(), jpeg: Data())

        #expect(RecipeRequest(text: "  eg ", photos: []) == nil)
        #expect(RecipeRequest(text: "", photos: []) == nil)
        #expect(RecipeRequest(text: "", photos: [photo]) == .photos([photo]))
        #expect(RecipeRequest(text: "https://a.b", photos: [photo])?.kind == .photos)
        #expect(RecipeRequest(text: " leek soup ", photos: []) == .describe("leek soup"))
    }
}

struct PhotoEncoderTests {
    private func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0.5, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func size(of image: Data) throws -> (width: Int, height: Int, type: String?) {
        let source = try #require(CGImageSourceCreateWithData(image as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (decoded.width, decoded.height, CGImageSourceGetType(source) as String?)
    }

    @Test func aLargePhotoBecomesAJPEGNoLongerThanTheLimit() throws {
        let jpeg = try #require(PhotoEncoder.jpeg(from: try png(width: 3000, height: 1500), longestSide: 1000))

        let result = try size(of: jpeg)
        #expect(result.type == UTType.jpeg.identifier)
        #expect(result.width == 1000)
        #expect(result.height == 500)
    }

    @Test func aSmallPhotoKeepsItsSize() throws {
        let jpeg = try #require(PhotoEncoder.jpeg(from: try png(width: 40, height: 30)))

        let result = try size(of: jpeg)
        #expect(result.type == UTType.jpeg.identifier)
        #expect((result.width, result.height) == (40, 30))
    }

    @Test func dataThatIsNotAnImageIsRefused() {
        #expect(PhotoEncoder.jpeg(from: Data("not a picture".utf8)) == nil)
    }
}
