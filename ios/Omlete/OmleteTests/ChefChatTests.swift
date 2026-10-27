import Foundation
import Testing
@testable import Omlete

/// Talking to Chef: what is sent, the reply as it streams, Undo and the
/// screens that refresh. The web's `Chef.tsx` and `lib/chef.ts` are the spec.
@MainActor struct ChefChatTests {
    private typealias Call = ScriptedTransport.Call

    private let phone = Phone()
    private let navigation = AppNavigation()
    private let chat: ChefChat
    private let askChef = Call(method: "POST", path: "/api/chef/chat")
    private let getList = Call(method: "GET", path: "/api/lists/list")
    private let getLists = Call(method: "GET", path: "/api/lists/")

    init() {
        var minted = 0
        let api = APIClient(baseURL: URL(string: Phone.apiAddress)!, transport: phone.transport)
        let kitchen = Kitchen(deps: KitchenDependencies(api: api, disk: MemoryCookStorage()))
        chat = ChefChat(deps: ChefChatDependencies(
            api: api, undo: phone.undo, library: phone.library, chef: phone.chef, kitchen: kitchen,
            navigation: navigation,
            newID: {
                minted += 1
                return "id\(minted)"
            }))
        navigation.push(.plan(Phone.listID), on: .home)
    }

    nonisolated private static func event(_ json: String) -> String { "data: \(json)\n\n" }

    nonisolated private static let addedMilk = [
        event(#"{"type":"start","messageId":"reply1"}"#),
        event(#"{"type":"tool-input-start","toolCallId":"ws","toolName":"web_search","providerExecuted":true}"#),
        event(#"{"type":"tool-output-available","toolCallId":"ws","output":{"results":[]},"providerExecuted":true}"#),
        event(#"{"type":"tool-input-available","toolCallId":"c1","toolName":"add_item","input":{"name":"oat milk"}}"#),
        event(#"{"type":"tool-output-available","toolCallId":"c1","output":{"done":"Added oat milk to Week","undo":"act1"}}"#),
        event(#"{"type":"text-start"}"#) + event(#"{"type":"text-delta","delta":"It's on Week."}"#),
        event(#"{"type":"finish"}"#) + "data: [DONE]\n\n",
    ]

    private func chefAnswers(_ pieces: [String] = Self.addedMilk, undo: Int = 200) {
        phone.serverAnswers { call in
            if call == askChef { return .streaming(pieces) }
            if call.path.hasPrefix("/api/chef/actions/") { return .status(undo) }
            if call == getLists { return .status(200, Phone.listsJSON) }
            if call.path == "/api/recipes/" || call.path == "/api/suggestions/" { return .status(200, "[]") }
            if call.path == "/api/weeks/current" { return .status(200, "null") }
            return nil
        }
    }

    private func sendAndWait(_ text: String = "add oat milk", photos: [RecipePhoto] = []) async {
        chat.send(text, photos: photos)
        await eventually { !chat.isReplying }
    }

    private func chatBodies() -> [[String: Any]] {
        zip(phone.transport.calls, phone.transport.bodies).filter { $0.0 == askChef }.map(\.1)
    }

    @Test func aMessageCarriesTheScreenItWasSentFrom() async throws {
        chefAnswers()
        await sendAndWait()
        let body = try #require(chatBodies().first)
        #expect(body["trigger"] as? String == "submit-message")
        #expect(body["id"] as? String == "id1")
        #expect((body["page"] as? [String: Any])?["path"] as? String == "/list/list")
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        let parts = try #require(messages[0]["parts"] as? [[String: Any]])
        #expect(parts.count == 1 && parts[0]["type"] as? String == "text" && parts[0]["text"] as? String == "add oat milk")
    }

    @Test func theReplyStreamsIntoTheChatWithItsChange() async {
        chefAnswers()
        await sendAndWait()
        #expect(chat.messages.count == 2)
        #expect(chat.messages[1].id == "reply1")
        #expect(chat.messages[1].changes == [ChefChange(done: "Added oat milk to Week", undo: "act1")])
        #expect(chat.lastLine == "It's on Week.")
        #expect(chat.failure == nil)
    }

    @Test func theScreenRefreshesAsTheChangeLandsNotWhenTheReplyEnds() async {
        chefAnswers()
        phone.transport.pausesStreams = true
        let before = phone.transport.calls.filter { $0 == getList }.count
        chat.send("add oat milk", photos: [])
        // Pieces 0–4 carry the change; the stream then waits with the reply unfinished.
        for sent in 1...4 {
            await eventually { phone.transport.piecesSent == sent }
            phone.transport.nextPiece()
        }
        await eventually { phone.transport.piecesSent == 5 }
        await eventually { phone.transport.calls.filter { $0 == getList }.count > before }
        #expect(phone.transport.calls.contains(getLists))
        #expect(chat.isReplying)
        phone.transport.pausesStreams = false
        phone.transport.nextPiece()
        await eventually { !chat.isReplying }
    }

    @Test func aRecipeOnScreenIsFetchedAgainWhenAChangeLands() async {
        chefAnswers()
        navigation.push(.recipe("curry"), on: .home)
        await sendAndWait()
        await eventually { phone.transport.calls.contains(.init(method: "GET", path: "/api/recipes/curry")) }
        let body = chatBodies().first
        #expect((body?["page"] as? [String: Any])?["path"] as? String == "/recipe/curry")
    }

    @Test func theNextMessageSendsChefsToolsBackButNotItsSearches() async throws {
        chefAnswers()
        await sendAndWait()
        await sendAndWait("thanks")
        let messages = try #require(chatBodies().last?["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let reply = try #require(messages[1]["parts"] as? [[String: Any]])
        #expect(reply.map { $0["type"] as? String } == ["tool-add_item", "text"])
        #expect(reply[0]["toolCallId"] as? String == "c1")
        #expect(reply[0]["state"] as? String == "output-available")
        #expect((reply[0]["input"] as? [String: Any])?["name"] as? String == "oat milk")
        #expect((reply[0]["output"] as? [String: Any])?["undo"] as? String == "act1")
    }

    @Test func photosGoAsDataURLsBeforeTheText() async throws {
        chefAnswers()
        await sendAndWait("save this", photos: [RecipePhoto(id: UUID(), jpeg: Data([0xFF, 0xD8, 0xFF]))])
        let messages = try #require(chatBodies().first?["messages"] as? [[String: Any]])
        let parts = try #require(messages[0]["parts"] as? [[String: Any]])
        #expect(parts.map { $0["type"] as? String } == ["file", "text"])
        #expect(parts[0]["mediaType"] as? String == "image/jpeg")
        #expect(parts[0]["url"] as? String == "data:image/jpeg;base64,/9j/")
    }

    @Test func nothingIsSentWithNoTextAndNoPhotos() async {
        chefAnswers()
        chat.send("   ", photos: [])
        #expect(chat.messages.isEmpty)
        #expect(!chat.isReplying)
    }

    @Test func withTheChatOnScreenTheChangeHasNoBanner() async {
        chefAnswers()
        chat.height = .half
        await sendAndWait()
        #expect(phone.undo.banner == nil)
    }

    @Test func withTheChatAwayTheReplysChangesGetOneBannerWithUndo() async {
        chefAnswers()
        chat.height = .bar
        await sendAndWait()
        #expect(phone.undo.banner?.message == "Added oat milk to Week")
        #expect(phone.undo.banner?.canUndo == true)
        phone.undo.undoTapped()
        await eventually { phone.undo.banner?.message == "Undid: Added oat milk to Week" }
        #expect(phone.transport.calls.contains(.init(method: "POST", path: "/api/chef/actions/act1/undo")))
        #expect(chat.undone == ["act1"])
    }

    @Test func overShopTheChatIsAwayWhateverItsHeight() async {
        chefAnswers()
        chat.height = .full
        navigation.startShopping(Phone.listID)
        await sendAndWait()
        #expect(phone.undo.banner?.message == "Added oat milk to Week")
        #expect((chatBodies().first?["page"] as? [String: Any])?["path"] as? String == "/shop/list")
    }

    @Test func undoGoesNewestFirst() async {
        chefAnswers()
        chat.height = .half
        chat.undo([ChefChange(done: "one", undo: "a1"), ChefChange(done: "two", undo: "a2")])
        await eventually { chat.undone.count == 2 }
        let undos = phone.transport.calls.filter { $0.path.hasPrefix("/api/chef/actions/") }.map(\.path)
        #expect(undos == ["/api/chef/actions/a2/undo", "/api/chef/actions/a1/undo"])
        #expect(phone.undo.banner == nil)
    }

    @Test func aChangeChangedSinceSaysSoInTheChat() async {
        chefAnswers(undo: 409)
        chat.height = .full
        chat.undo([ChefChange(done: "one", undo: "a1")])
        await eventually { chat.failure != nil }
        #expect(chat.failure == "That's changed since, so it can't be undone")
        #expect(chat.undone.isEmpty)
        // The screen is refreshed anyway: something else changed it.
        await eventually { phone.transport.calls.contains(getLists) }
    }

    @Test func anUndoThatFailsAwayFromTheChatSaysSoInTheBanner() async {
        chefAnswers(undo: 500)
        chat.undo([ChefChange(done: "one", undo: "a1")])
        await eventually { phone.undo.banner != nil }
        #expect(phone.undo.banner?.message == "Couldn't undo that. Try again?")
        #expect(chat.failure == nil)
    }

    @Test func anErrorInTheStreamKeepsWhatCameBeforeIt() async {
        chefAnswers([
            Self.event(#"{"type":"text-delta","delta":"Let me look"}"#),
            Self.event(#"{"type":"error","errorText":"overloaded"}"#),
            Self.event(#"{"type":"text-delta","delta":" never shown"}"#),
        ])
        await sendAndWait()
        #expect(chat.failure == "Chef couldn't answer. Try again?")
        #expect(chat.lastLine == "Let me look")
    }

    @Test func aRefusedRequestAndNoConnectionSayDifferentThings() async {
        phone.serverAnswers { $0 == askChef ? .status(500) : nil }
        await sendAndWait()
        #expect(chat.failure == "Chef couldn't answer. Try again?")
        #expect(chat.messages.count == 1)

        phone.serverIsUnreachable()
        await sendAndWait("again")
        #expect(chat.failure == "Chef needs a connection.")
    }

    @Test func aNewChatDropsTheReplyStillComing() async {
        chefAnswers()
        phone.transport.pausesStreams = true
        chat.send("add oat milk", photos: [])
        await eventually { phone.transport.piecesSent > 0 }
        chat.reset()
        phone.transport.pausesStreams = false
        phone.transport.nextPiece()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(chat.messages.isEmpty)
        #expect(!chat.isReplying)
        #expect(chat.failure == nil)

        await sendAndWait("hello")
        #expect(chatBodies().last?["id"] as? String != "id1")
    }

    @Test func theChefTabOpensAtHalfAndCloses() {
        chat.toggle()
        #expect(chat.height == .half)
        chat.height = .bar
        chat.toggle()
        #expect(chat.height == .closed)
    }

    @Test func thePageFollowsTheTabAndItsStack() {
        let nav = AppNavigation()
        #expect(nav.chefPage == .home)
        nav.tab = .discover
        #expect(nav.chefPage == .discover)
        nav.tab = .recipes
        #expect(nav.chefPage == .recipes)
        nav.push(.recipe("r1"), on: .recipes)
        #expect(nav.chefPage == .recipe("r1"))
        nav.push(.settings, on: .recipes)
        #expect(nav.chefPage == .settings)
        nav.tab = .home
        nav.push(.plan("l1"), on: .home)
        #expect(nav.chefPage == .list("l1"))
        nav.startCooking("r2")
        #expect(nav.chefPage == .cook("r2"))
    }
}
