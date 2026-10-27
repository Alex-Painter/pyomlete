import Foundation
import Testing
@testable import Omlete

/// Reading Chef's stream: the AI SDK's UI message stream as the server sends
/// it, and the reply it builds. The web's `client/src/lib/chef.ts` is the spec.
struct ChefStreamTests {
    /// A reply that searches the web, adds a meal to a list, and says so.
    static let reply = """
        data: {"type":"start","messageId":"msg1"}

        data: {"type":"start-step"}

        data: {"type":"tool-input-start","toolCallId":"ws1","toolName":"web_search","providerExecuted":true}

        data: {"type":"tool-input-available","toolCallId":"ws1","toolName":"web_search","input":{"query":"dal"},"providerExecuted":true}

        data: {"type":"tool-output-available","toolCallId":"ws1","output":[{"url":"https://example.com/dal"}],"providerExecuted":true}

        data: {"type":"tool-input-start","toolCallId":"c1","toolName":"add_recipe_to_list"}

        data: {"type":"tool-input-delta","toolCallId":"c1","inputTextDelta":"{\\"list_id\\""}

        data: {"type":"tool-input-available","toolCallId":"c1","toolName":"add_recipe_to_list","input":{"list_id":"l1","recipe_id":"r1"}}

        data: {"type":"tool-output-available","toolCallId":"c1","output":{"done":"Added Dal to Week","undo":"a1","list_id":"l1"}}

        data: {"type":"text-start","id":"t1"}

        data: {"type":"text-delta","id":"t1","delta":"Done — "}

        data: {"type":"text-delta","id":"t1","delta":"it's on Week. 🍲"}

        data: {"type":"text-end","id":"t1"}

        data: {"type":"finish"}

        data: [DONE]


        """

    private func events(_ stream: String, cutEvery size: Int) throws -> [ChefStreamEvent] {
        var reader = ServerSentEvents()
        let bytes = Data(stream.utf8)
        var payloads: [ServerSentEvents.Payload] = []
        for start in stride(from: 0, to: bytes.count, by: size) {
            payloads += reader.feed(bytes[start..<min(start + size, bytes.count)])
        }
        let ended = payloads.firstIndex(of: .done) ?? payloads.endIndex
        return try payloads[..<ended].map { payload in
            guard case .data(let data) = payload else { fatalError() }
            return try ChefStreamEvent(payload: data)
        }
    }

    private func build(_ events: [ChefStreamEvent]) -> ChefMessage {
        var message = ChefMessage(id: "local", role: .assistant, parts: [])
        events.forEach { message.apply($0) }
        return message
    }

    @Test(arguments: [1, 2, 3, 7, 64, 100_000])
    func theReplyIsTheSameHoweverTheBytesAreCut(size: Int) throws {
        // Cut one byte at a time, the emoji and the dash arrive in pieces.
        let message = build(try events(Self.reply, cutEvery: size))
        #expect(message.id == "msg1")
        #expect(message.parts.count == 3)
        #expect(message.parts.last == .text("Done — it's on Week. 🍲"))
        #expect(message.lastLine == "Done — it's on Week. 🍲")
        #expect(message.changes == [ChefChange(done: "Added Dal to Week", undo: "a1")])
    }

    @Test func aToolKeepsItsInputAndEndsDoneOrFailed() throws {
        let message = build(try events(Self.reply, cutEvery: 1000))
        guard case .tool(let search) = message.parts[0], case .tool(let add) = message.parts[1] else {
            Issue.record("expected two tools first, got \(message.parts)")
            return
        }
        #expect(search.isWebSearch && search.providerExecuted && search.change == nil)
        #expect(search.input == .object(["query": .string("dal")]))
        #expect(add.input == .object(["list_id": .string("l1"), "recipe_id": .string("r1")]))
        #expect(!add.providerExecuted)

        var failed = message
        failed.apply(.toolInput(callID: "c2", name: "delete_list", input: nil, providerExecuted: false))
        failed.apply(.toolFailed(callID: "c2", error: "boom"))
        guard case .tool(let deleted) = failed.parts.last else { Issue.record("no tool"); return }
        #expect(deleted.state == .failed("boom"))
        #expect(failed.changes.count == 1)
    }

    @Test func onlyAnOutputWithBothDoneAndUndoIsAChange() throws {
        var message = ChefMessage(id: "m", role: .assistant, parts: [])
        for (id, output) in [
            ("c1", #"{"error":"No such list"}"#), ("c2", #"{"done":"Renamed it"}"#), ("c3", #"[1,2]"#),
            ("c4", #"{"done":"Deleted Week","undo":"a4"}"#),
        ] {
            message.apply(.toolInput(callID: id, name: "x", input: nil, providerExecuted: false))
            message.apply(.toolOutput(callID: id, output: try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))))
        }
        #expect(message.changes == [ChefChange(done: "Deleted Week", undo: "a4")])
    }

    @Test func textArrivingWithNoTextStartStillShows() {
        var message = ChefMessage(id: "m", role: .assistant, parts: [])
        message.apply(.textDelta("Hi"))
        message.apply(.textDelta(" there"))
        message.apply(.textStart)
        message.apply(.textDelta("Again"))
        #expect(message.parts == [.text("Hi there"), .text("Again")])
    }

    @Test func anOutputForACallNeverStartedIsIgnored() {
        var message = ChefMessage(id: "m", role: .assistant, parts: [])
        message.apply(.toolOutput(callID: "ghost", output: .object(["done": .string("x"), "undo": .string("y")])))
        #expect(message.parts.isEmpty)
    }

    @Test func anErrorEventCarriesItsText() throws {
        let failure = try events(#"data: {"type":"error","errorText":"model unavailable"}\#n\#n"#, cutEvery: 5)
        #expect(failure == [.failed("model unavailable")])
    }

    @Test func carriageReturnLineEndsAndOtherFieldsAreRead() throws {
        let stream = "event: message\r\ndata: {\"type\":\"text-delta\",\"delta\":\"a\"}\r\n\r\n: comment\r\n\r\ndata: {\"type\":\"reasoning-delta\",\"delta\":\"x\"}\r\n\r\n"
        #expect(try events(stream, cutEvery: 3) == [.textDelta("a"), .other])
    }

    @Test func anUnfinishedEventWaitsForTheRestOfIt() {
        var reader = ServerSentEvents()
        #expect(reader.feed(Data(#"data: {"type":"text-start"}"#.utf8)).isEmpty)
        #expect(reader.feed(Data("\n".utf8)).isEmpty)
        #expect(reader.feed(Data("\n".utf8)) == [.data(Data(#"{"type":"text-start"}"#.utf8))])
    }

    @Test(arguments: ["not json", #"{"delta":"no type"}"#, "[1]"])
    func aPayloadThatIsNotAnEventThrows(payload: String) {
        #expect(throws: (any Error).self) { try ChefStreamEvent(payload: Data(payload.utf8)) }
    }

    @Test func jsonComesBackOutAsItWentIn() throws {
        let text = #"{"a":[1,2.5,true,null,"x"],"b":{"c":false}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        let again = try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(value))
        #expect(again == value)
        #expect(value["a"] == .array([.number(1), .number(2.5), .bool(true), .null, .string("x")]))
    }

    @Test func eachScreenHasTheWebsPath() {
        let list: ListID = "65f0a1b2c3d4e5f6a7b8c9d0"
        let recipe: RecipeID = "65f0a1b2c3d4e5f6a7b8c9d1"
        #expect(ChefPage.home.path == "/")
        #expect(ChefPage.discover.path == "/discover")
        #expect(ChefPage.recipes.path == "/recipes")
        #expect(ChefPage.addRecipe.path == "/create")
        #expect(ChefPage.settings.path == "/settings")
        #expect(ChefPage.list(list).path == "/list/65f0a1b2c3d4e5f6a7b8c9d0")
        #expect(ChefPage.shop(list).path == "/shop/65f0a1b2c3d4e5f6a7b8c9d0")
        #expect(ChefPage.recipe(recipe).path == "/recipe/65f0a1b2c3d4e5f6a7b8c9d1")
        #expect(ChefPage.cook(recipe).path == "/cook/65f0a1b2c3d4e5f6a7b8c9d1")
    }
}
