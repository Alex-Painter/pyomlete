import Foundation
import Testing
@testable import Omlete

/// A photo the API made is a path on the API; one from a recipe's page is a full URL.
struct MediaURLTests {
    private let api = URL(string: "https://omlete-api.example")!

    @Test func aPathOnTheAPIIsResolvedAgainstIt() {
        #expect(Wire.media("/api/recipe-images/abc", base: api)?.absoluteString == "https://omlete-api.example/api/recipe-images/abc")
    }

    @Test func aFullURLIsUsedAsItIs() {
        let url = "https://images.example.com/curry.jpg"
        #expect(Wire.media(url, base: api)?.absoluteString == url)
    }

    @Test func noPictureIsNoURL() {
        #expect(Wire.media(nil, base: api) == nil)
        #expect(Wire.media("", base: api) == nil)
    }

    @Test func aRecipesPathIsResolvedWhenItIsRead() throws {
        let json = #"[{"id":"r1","title":"Curry","image_url":"/api/recipe-images/i1"}]"#
        let recipes = try Wire.recipes(Data(json.utf8))
        #expect(recipes.first?.imageURL?.absoluteString == APIEnvironment.baseURL.absoluteString + "/api/recipe-images/i1")
    }
}

@MainActor struct GenerateImageTests {
    private let stove = Stove()
    private let generate = ScriptedTransport.Call(method: "POST", path: "/api/recipes/curry/image")

    @Test func aMadePhotoBecomesTheRecipesPictureAndTheLibraryIsTold() async {
        stove.serverAnswers { [generate] call in
            call == generate ? .status(200, #"{"id":"curry","image_url":"/api/recipe-images/new"}"#) : nil
        }
        await stove.store.load()

        stove.store.makePhoto()
        #expect(stove.store.photo == .making)
        await eventually { stove.store.photo == .idle }

        guard case .ready(let recipe) = stove.store.page else { Issue.record("no recipe"); return }
        #expect(recipe.imageURL?.path() == "/api/recipe-images/new")
        #expect(stove.reportedSaves.last?.imageURL?.path() == "/api/recipe-images/new")
        #expect(stove.transport.calls.filter { $0 == generate }.count == 1)
    }

    @Test func aSecondTapWhileOneIsBeingMadeSendsNothing() async {
        stove.transport.holding = true
        stove.store.makePhoto()
        stove.store.makePhoto()
        await eventually { stove.transport.calls.contains(generate) }
        stove.transport.release()
        await eventually { stove.store.photo != .making }
        #expect(stove.transport.calls.filter { $0 == generate }.count == 1)
    }

    @Test func photosNotSetUpShowsTheServersSentence() async {
        stove.serverAnswers { [generate] call in
            call == generate ? .status(503, #"{"detail":"Photos aren't set up yet: the server has no FAL_KEY."}"#) : nil
        }
        stove.store.makePhoto()
        await eventually { stove.store.photo != .making }
        #expect(stove.store.photo == .failed("Photos aren't set up yet: the server has no FAL_KEY."))
    }

    @Test func aFailureWithNoSentenceSaysTryAgain() async {
        stove.serverAnswers { [generate] call in call == generate ? .status(500, "oops") : nil }
        stove.store.makePhoto()
        await eventually { stove.store.photo != .making }
        #expect(stove.store.photo == .failed(PhotoState.fallback))
    }

    @Test func noSignalSaysItNeedsAConnection() async {
        stove.serverAnswers { [generate] call in call == generate ? .unreachable : nil }
        stove.store.makePhoto()
        await eventually { stove.store.photo != .making }
        #expect(stove.store.photo == .failed("Couldn't reach Omlete. Making a photo needs a connection."))
    }
}
