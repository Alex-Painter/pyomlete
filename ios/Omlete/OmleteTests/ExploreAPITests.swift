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

    @Test func recipeSummariesCarryRatingSourceAndIngredientCount() async throws {
        serverAnswers(200, """
            [{"id":"a","title":"A","rating":4,"total_minutes":20,"source_name":"example.com","image_url":null,"ingredient_count":7},
             {"id":"b","title":"B"}]
            """)

        #expect(try await api.recipes() == [
            RecipeSummary(id: "a", title: "A", totalMinutes: 20, rating: 4, sourceName: "example.com", ingredientCount: 7),
            RecipeSummary(id: "b", title: "B"),
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

    @Test func aSourceThatIsNotAWebPageKeepsItsNameAndLosesItsLink() async throws {
        serverAnswers(200, #"[{"id":"1","title":"Odd","status":"new","source_url":"tel:0123456789","source_name":"Somewhere"}]"#)

        #expect(try await api.suggestions().first?.source == RecipeSource(name: "Somewhere", url: nil))
    }


    nonisolated static func jobJSON(_ status: String, recipe: String? = nil, failure: String? = nil) -> String {
        let quoted = { (value: String?) in value.map { #""\#($0)""# } ?? "null" }
        return #"{"key":"job1","kind":"link","status":"\#(status)","recipe_id":\#(quoted(recipe)),"failure":\#(quoted(failure))}"#
    }

    private func job(_ kind: RecipeRequest.Kind = .link) -> RecipeJob {
        RecipeJob(key: "job1", kind: kind, startedAt: Date(timeIntervalSinceReferenceDate: 0))
    }

    @Test func aLinkIsStartedUnderItsJobsKey() async {
        serverAnswers(202, Self.jobJSON("working"))

        #expect(await api.startRecipe(.link("https://example.com/traybake"), as: job()) == .taken)
        #expect(transport.calls == [Call(method: "PUT", path: "/api/recipe-jobs/job1/link")])
        #expect(transport.bodies[0] as? [String: String] == ["url": "https://example.com/traybake"])
    }

    @Test func aDescriptionIsStartedFromItsPrompt() async {
        serverAnswers(202, Self.jobJSON("working"))

        #expect(await api.startRecipe(.describe("a traybake"), as: job(.describe)) == .taken)
        #expect(transport.calls == [Call(method: "PUT", path: "/api/recipe-jobs/job1/describe")])
        #expect(transport.bodies[0] as? [String: String] == ["prompt": "a traybake"])
    }

    @Test func photosAreStartedAsOneUploadOfEveryPage() async throws {
        serverAnswers(202, Self.jobJSON("working"))
        let photos = [RecipePhoto(id: UUID(), jpeg: Data("first".utf8)), RecipePhoto(id: UUID(), jpeg: Data("second".utf8))]

        #expect(await api.startRecipe(.photos(photos), as: job(.photos)) == .taken)

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path() == "/api/recipe-jobs/job1/photos")
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        let boundary = try #require(contentType.split(separator: "boundary=").last)
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body == [
            "--\(boundary)", #"Content-Disposition: form-data; name="files"; filename="photo-1.jpg""#,
            "Content-Type: image/jpeg", "", "first",
            "--\(boundary)", #"Content-Disposition: form-data; name="files"; filename="photo-2.jpg""#,
            "Content-Type: image/jpeg", "", "second",
            "--\(boundary)--", "",
        ].joined(separator: "\r\n"))
    }

    /// 200 is a job the server already had, and what it says in the body is for the next look.
    @Test(arguments: [(202, "{}"), (200, jobJSON("saved", recipe: "traybake")), (200, "[]")])
    func anyAnswerThatTheServerHasTheJobIsTaken(status: Int, body: String) async {
        serverAnswers(status, body)

        #expect(await api.startRecipe(.link("https://example.com/x"), as: job()) == .taken)
    }

    @Test(arguments: [
        (nil, RecipeStart.unanswered(.noConnection)), (500, .unanswered(.serverTrouble)), (503, .unanswered(.serverTrouble)),
        (408, .unanswered(.serverTrouble)), (429, .refused(.busy)), (413, .refused(.other)), (422, .refused(.other)),
        (404, .refused(.other)),
    ])
    func onlyAnAnswerThatRefusesTheJobIsARefusal(status: Int?, expected: RecipeStart) async {
        transport.reply = { _ in status.map { .status($0) } ?? .unreachable }

        #expect(await api.startRecipe(.describe("leek and potato soup"), as: job(.describe)) == expected)
    }

    @Test(arguments: [
        (jobJSON("working"), RecipeJobCheck.working),
        (jobJSON("already_imported", recipe: "traybake"), .finished(.alreadySaved("traybake"))),
        (jobJSON("failed", failure: "link_blocked"), .finished(.failed(.linkBlocked))),
        (jobJSON("failed", failure: "no_recipe_on_page"), .finished(.failed(.noRecipeOnPage))),
        (jobJSON("failed", failure: "site_did_not_respond"), .finished(.failed(.siteDidNotRespond))),
        (jobJSON("failed", failure: "other"), .finished(.failed(.other))),
        (jobJSON("failed", failure: "from_the_future"), .finished(.failed(.other))),
        (jobJSON("failed"), .finished(.failed(.other))),
        (jobJSON("simmering"), .unanswered(.serverTrouble)),
        (jobJSON("saved"), .unanswered(.serverTrouble)),
        (jobJSON("already_imported"), .unanswered(.serverTrouble)),
        ("[]", .unanswered(.serverTrouble)),
    ])
    func aLookAtAJobReadsHowItStandsAndWhatItCannotReadIsNoAnswer(body: String, expected: RecipeJobCheck) async {
        serverAnswers(200, body)

        #expect(await api.checkRecipe(job()) == expected)
        #expect(transport.calls == [Call(method: "GET", path: "/api/recipe-jobs/job1")])
    }

    @Test func aSavedJobIsAnsweredWithItsRecipeFetched() async {
        transport.reply = { call in
            call.path == "/api/recipes/traybake" ? .status(200, Self.traybakeJSON) : .status(200, Self.jobJSON("saved", recipe: "traybake"))
        }

        guard case .finished(.saved(let recipe)) = await api.checkRecipe(job(.describe)) else {
            Issue.record("not saved")
            return
        }
        #expect(recipe.title == "Traybake")
        #expect(transport.calls == [
            Call(method: "GET", path: "/api/recipe-jobs/job1"), Call(method: "GET", path: "/api/recipes/traybake"),
        ])
    }

    @Test(arguments: [
        (nil, Silence.noConnection), (500, .serverTrouble), (503, .serverTrouble), (429, .serverTrouble), (422, .serverTrouble),
    ])
    func aLookThatCouldNotBeAnsweredSaysNothingAboutTheJobAndSaysWhy(status: Int?, why: Silence) async {
        transport.reply = { _ in status.map { .status($0) } ?? .unreachable }

        #expect(await api.checkRecipe(job()) == .unanswered(why))
    }

    @Test(arguments: [(nil, Silence.noConnection), (500, .serverTrouble), (200, .serverTrouble)])
    func aSavedJobWhoseRecipeCannotBeFetchedOrReadIsAskedAgain(status: Int?, why: Silence) async {
        transport.reply = { call in
            guard call.path == "/api/recipes/traybake" else { return .status(200, Self.jobJSON("saved", recipe: "traybake")) }
            return status.map { .status($0, "[]") } ?? .unreachable
        }

        #expect(await api.checkRecipe(job()) == .unanswered(why))
    }

    @Test func aKeyTheServerWasNeverSentIsUnknownWhichIsNotAFailure() async {
        serverAnswers(404, #"{"detail":"Recipe job not found"}"#)

        #expect(await api.checkRecipe(job()) == .unknown)
    }

    @Test func aSavedJobWhoseRecipeHasBeenDeletedSaysSo() async {
        transport.reply = { call in
            call.path == "/api/recipes/traybake" ? .status(404) : .status(200, Self.jobJSON("saved", recipe: "traybake"))
        }

        #expect(await api.checkRecipe(job()) == .recipeGone)
    }

    @Test func onlyFindingIdeasWaitsOnAModelAndIsGivenLonger() async throws {
        serverAnswers(200, "[]")

        _ = try await api.lists()
        _ = try await api.suggestions()
        try await api.findIdeas(TuneSettings())
        _ = await api.startRecipe(.describe("soup of the day"), as: job(.describe))
        _ = await api.checkRecipe(job(.describe))

        let standard = URLRequest(url: URL(string: "http://phone.test")!).timeoutInterval
        #expect(transport.requests.map(\.timeoutInterval) == [standard, standard, 180, standard, standard])
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

    @Test func anEditReplacesTheTitleMethodAndEveryIngredientFieldAndAnswersWithTheSavedRecipe() async throws {
        serverAnswers(200, Self.traybakeJSON)
        let edit = RecipeEdit(
            title: "Sunday traybake", steps: ["Roast.", "Dress."],
            ingredients: [
                .init(name: "potatoes", amount: 1.5, unit: "kg", note: "halved", group: "For the traybake", category: "Fresh Produce"),
                .init(name: "oil", amount: 2, unit: "tbsp", group: "For the dressing", category: "Pantry", isOnList: false),
            ])

        let saved = try await api.updateRecipe("traybake", edit)

        #expect(transport.calls == [Call(method: "PUT", path: "/api/recipes/traybake")])
        let body = transport.bodies[0]
        #expect(body["title"] as? String == "Sunday traybake")
        #expect(body["instructions"] as? [String] == ["Roast.", "Dress."])
        let sent = try #require(body["ingredients"] as? [NSDictionary])
        #expect(sent == [
            ["name": "potatoes", "amount": 1.5, "unit": "kg", "note": "halved", "group": "For the traybake",
             "category": "Fresh Produce", "excluded_from_list": false],
            ["name": "oil", "amount": 2, "unit": "tbsp", "group": "For the dressing", "category": "Pantry",
             "excluded_from_list": true],
        ])
        #expect(saved.title == "Traybake")
        #expect(saved.ingredients.count == 4)
    }

    /// The server's `IngredientRecipe` takes a string for `unit` and `category`
    /// and refuses null for either, with a 422 that would lose the whole save.
    @Test func anIngredientWithNoQuantityUnitOrAisleIsSentWithoutANullTheServerWouldRefuse() async throws {
        serverAnswers(200, Self.traybakeJSON)

        _ = try await api.updateRecipe("traybake", RecipeEdit(title: "T", steps: [], ingredients: [.init(name: "salt")]))

        let sent = try #require((transport.bodies[0]["ingredients"] as? [NSDictionary])?.first)
        #expect(sent == ["name": "salt", "unit": "", "excluded_from_list": false])
    }

    @Test func anEditTheServerRefusesOrNeverGetsIsAnError() async {
        let edit = RecipeEdit(title: "T", steps: [], ingredients: [])

        serverAnswers(404)
        await #expect(throws: APIError.rejected(404)) { try await api.updateRecipe("gone", edit) }

        transport.reply = { _ in .unreachable }
        await #expect(throws: APIError.unreachable) { try await api.updateRecipe("traybake", edit) }
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
