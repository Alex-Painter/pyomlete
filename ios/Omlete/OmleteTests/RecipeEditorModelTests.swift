import Foundation
import Testing
@testable import Omlete

/// What a tap on Save does and says, over a real `CookStore` and a scripted server.
@MainActor struct RecipeEditorModelTests {
    private typealias Call = ScriptedTransport.Call
    private typealias Phase = RecipeEditorModel.Phase
    private let stove = Stove()
    private let put = Call(method: "PUT", path: "/api/recipes/curry")

    private nonisolated static let unreachable =
        "Couldn't reach Omlete, so this may not be saved. Saving an edit needs a connection. Your changes are still here, and saving again is safe."
    private nonisolated static let gone = "This recipe doesn't exist any more, so it can't be saved."
    private nonisolated static let failed = "Couldn't save. Your changes are still here, so try again."

    private var puts: Int { stove.transport.calls.count(where: { $0 == put }) }

    private var pageTitle: String? {
        if case .ready(let recipe) = stove.store.page { recipe.title } else { nil }
    }

    /// The server answers a PUT with the title it was sent, and `override` first.
    private func serverSavesEdits(_ override: @escaping (Call) -> ScriptedTransport.Reply? = { _ in nil }) {
        stove.serverAnswers { [put, transport = stove.transport] call in
            if let reply = override(call) { return reply }
            guard call == put, let title = transport.bodies.last?["title"] as? String else { return nil }
            return .status(200, Stove.recipeJSON.replacingOccurrences(of: #""title":"Curry""#, with: #""title":"\#(title)""#))
        }
    }

    /// The editor as Edit recipe opens it, with `change` typed in.
    private func editor(_ change: (inout RecipeDraft) -> Void = { $0.title = "Green curry" }) async -> RecipeEditorModel {
        await stove.store.load()
        var draft = RecipeDraft(.fixture())
        if case .ready(let recipe) = stove.store.page { draft = RecipeDraft(recipe) }
        change(&draft)
        return RecipeEditorModel(draft: draft, store: stove.store)
    }

    @Test func aSaveThatSucceedsIsOnePutAndFinishes() async {
        serverSavesEdits()
        let model = await editor()
        #expect(model.hasChanges)

        await model.save()

        #expect(model.phase == .finished)
        #expect(puts == 1)
        #expect(pageTitle == "Green curry")
    }

    @Test func aSaveWithNoSignalSaysSoKeepsTheDraftAndWorksOnceTheServerIsBack() async {
        serverSavesEdits { [put] in $0 == put ? .unreachable : nil }
        let model = await editor()

        await model.save()

        #expect(model.phase == .stopped(Self.unreachable))
        #expect(model.draft.title == "Green curry")
        #expect(pageTitle == "Curry")

        serverSavesEdits()
        await model.save()

        #expect(model.phase == .finished)
        #expect(pageTitle == "Green curry")
    }

    @Test(arguments: [
        (ScriptedTransport.Reply.lost, unreachable), (.status(404), gone), (.status(422), failed), (.status(500), failed),
        (.status(200, "not a recipe"), failed),
    ])
    func aSaveTheServerDoesNotTakeSaysWhyAndKeepsTheDraft(reply: ScriptedTransport.Reply, message: String) async {
        serverSavesEdits { [put] in $0 == put ? reply : nil }
        let model = await editor()

        await model.save()

        #expect(model.phase == .stopped(message))
        #expect(model.draft.title == "Green curry")
        #expect(model.hasChanges)
        #expect(pageTitle == "Curry")
    }

    @Test func aSecondTapWhileSavingSendsNothingMore() async {
        serverSavesEdits()
        let model = await editor()
        stove.transport.holding = true

        async let first: Void = model.save()
        await eventually { puts == 1 }
        #expect(model.phase == .saving)
        async let second: Void = model.save()
        stove.transport.release()
        await first
        await second

        #expect(model.phase == .finished)
        #expect(puts == 1)
    }

    @Test func aTapAfterTheSaveLandedSendsNothingMore() async {
        serverSavesEdits()
        let model = await editor()

        await model.save()
        await model.save()

        #expect(puts == 1)
    }

    @Test func aQuantityThatIsNotANumberStopsTheSaveNamesItsRowsAndSendsNothing() async {
        serverSavesEdits()
        let model = await editor {
            $0.ingredients[0].quantity = "a few"
            $0.ingredients[1].quantity = "lots"
        }

        await model.save()

        #expect(model.phase == .stopped("The quantity for onions and rice has to be a plain number, or empty."))
        #expect(model.unreadable == [0, 1])
        #expect(puts == 0)
    }

    @Test func theMessageGoesWhenTheDraftChangesAndStaysWhenItDoesNot() async {
        serverSavesEdits()
        let model = await editor { $0.ingredients[0].quantity = "a few" }
        await model.save()

        model.draft.title = model.draft.title
        #expect(model.phase != .editing)

        model.draft.ingredients[0].quantity = "3"

        #expect(model.phase == .editing)
        #expect(model.unreadable.isEmpty)
    }

    @Test func savingWithNothingChangedFinishesAndSendsNothing() async {
        serverSavesEdits()
        let model = await editor { _ in }
        #expect(!model.hasChanges)

        await model.save()

        #expect(model.phase == .finished)
        #expect(puts == 0)
    }

    @Test func aBlankRowAddedIsNotAChangeAndRemovingARowIs() async {
        let model = await editor { _ in }

        model.draft.addIngredient()
        #expect(!model.hasChanges)

        model.draft.ingredients.removeFirst()
        #expect(model.hasChanges)
    }
}
