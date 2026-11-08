import Foundation
import Testing
@testable import Omlete

/// Open beside Undo on what Chef made. The web's `linkIn` in client/src/lib/chef.ts is the spec.
struct ChefLinkTests {
    private func tool(_ output: String) throws -> ChefTool {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
        return ChefTool(callID: "c1", name: "create_recipe", input: nil, state: .done(value), providerExecuted: false)
    }

    @Test func aRecipeChefMadeLinksToIt() throws {
        let made = try tool(#"{"done":"Added Dal to your recipes","undo":"a1","recipe_id":"r9"}"#)
        #expect(made.change == ChefChange(done: "Added Dal to your recipes", undo: "a1", link: .recipe("r9")))
    }

    @Test func aListChefStartedLinksToIt() throws {
        let made = try tool(#"{"done":"Started a list, Weekend","undo":"a2","list_id":"l3"}"#)
        #expect(made.change?.link == .list("l3"))
    }

    @Test func aChangeThatMadeNothingHasNoLink() throws {
        #expect(try tool(#"{"done":"Renamed the list","undo":"a"}"#).change?.link == nil)
    }

    @Test func aRecipeAlreadySavedHasNoUndoButStillLinks() throws {
        let found = try tool(#"{"already_saved":true,"recipe_id":"r1"}"#)
        #expect(found.change == nil)
        #expect(found.alreadySaved == .recipe("r1"))
        #expect(try tool(#"{"done":"Renamed the list","undo":"a"}"#).alreadySaved == nil)
        #expect(try tool(#""No such id""#).alreadySaved == nil)
    }

    @MainActor @Test func openingALinkPushesItOnTheTabOnShow() {
        let navigation = AppNavigation()
        navigation.tab = .discover
        navigation.open(.recipe("r1"))
        navigation.open(.list("l1"))
        #expect(navigation[.discover] == [.recipe("r1"), .plan("l1")])
    }
}
