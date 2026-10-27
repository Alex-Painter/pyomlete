import Foundation
import Testing
@testable import Omlete

@MainActor struct ChefMemoryTests {
    private typealias Call = ScriptedTransport.Call

    /// Told after inferred, as nothing promises the server's order, and one
    /// stance and one source from a newer server.
    static let preferencesJSON = """
        [{"id":"p1","subject":"curry","stance":"prefer","evidence":"Rated 4 curries 5 stars","source":"inferred","forgotten":false},
         {"id":"p2","subject":"mushrooms","stance":"never","evidence":"You said so on 18 Oct","source":"told","forgotten":false},
         {"id":"p3","subject":"fish","stance":"more","evidence":"You said so on 19 Oct","source":"told","forgotten":false},
         {"id":"p4","subject":"tofu","stance":"allergic","evidence":"You said so on 20 Oct","source":"told","forgotten":false},
         {"id":"p5","subject":"rice","stance":"less","evidence":"Seen often","source":"guessed","forgotten":false}]
        """

    private let phone = Phone()
    private let get = Call(method: "GET", path: "/api/preferences")
    private let patchMushrooms = Call(method: "PATCH", path: "/api/preferences/p2")

    private var memory: ChefMemory { phone.chef.memory }

    init() {
        serverAnswers()
    }

    private func serverAnswers(_ override: @escaping (Call) -> ScriptedTransport.Reply? = { _ in nil }) {
        phone.serverAnswers { call in
            if let reply = override(call) { return reply }
            return call.description == "GET /api/preferences" ? .status(200, Self.preferencesJSON) : nil
        }
    }

    private var patches: [[String: Any]] {
        zip(phone.transport.calls, phone.transport.bodies).filter { $0.0 == patchMushrooms }.map(\.1)
    }

    private var mushrooms: Preference { memory.told[0] }

    @Test func toldAndNoticedAreGroupedWithLabelsAndEvidence() async {
        await memory.load()

        #expect(memory.status == .loaded)
        #expect(memory.told.map(\.subject) == ["mushrooms", "fish"])
        #expect(memory.noticed.map(\.subject) == ["curry"])
        #expect(memory.told.map(\.stance.label) == ["Never", "More"])
        #expect(memory.noticed[0].stance.label == "Likes")
        #expect(memory.told[0].evidence == "You said so on 18 Oct")
    }

    @Test func aStanceOrSourceThisBuildDoesNotKnowIsLeftOut() async {
        await memory.load()

        #expect(!memory.preferences.contains { $0.subject == "tofu" || $0.subject == "rice" })
    }

    @Test func aFailedFirstLoadSaysSoAndAFailedLaterOneKeepsTheRows() async {
        serverAnswers { _ in .unreachable }
        await memory.load()
        #expect(memory.status == .failed)

        serverAnswers()
        await memory.load()
        #expect(memory.status == .loaded)

        serverAnswers { _ in .unreachable }
        await memory.load()
        #expect(memory.status == .loaded)
        #expect(memory.preferences.count == 3)
    }

    @Test func nothingKnownIsLoadedAndEmpty() async {
        serverAnswers { $0 == get ? .status(200, "[]") : nil }
        await memory.load()

        #expect(memory.status == .loaded)
        #expect(memory.preferences.isEmpty)
    }

    @Test func forgetHidesTheRowAtOnceAndTellsTheServerWithUndoOnTheBanner() async {
        await memory.load()

        memory.forget(mushrooms)

        #expect(memory.told.map(\.subject) == ["fish"])
        #expect(phone.undo.banner?.message == "Forgot mushrooms")
        #expect(phone.undo.banner?.canUndo == true)
        await eventually { patches.count == 1 }
        #expect(patches[0]["forgotten"] as? Bool == true)
    }

    @Test func undoPutsTheRowBackInItsPlaceAndTellsTheServer() async {
        await memory.load()
        memory.forget(mushrooms)
        await eventually { patches.count == 1 }

        phone.undo.undoTapped()

        #expect(memory.told.map(\.subject) == ["mushrooms", "fish"])
        await eventually { patches.count == 2 }
        #expect(patches[1]["forgotten"] as? Bool == false)
    }

    @Test func undoTappedBeforeTheForgetIsAnsweredIsSentAfterIt() async {
        await memory.load()
        phone.transport.holding = true
        memory.forget(mushrooms)
        await eventually { patches.count == 1 }

        phone.undo.undoTapped()
        #expect(memory.told.map(\.subject) == ["mushrooms", "fish"])
        // Undo waits for the forget's answer, so the server ends remembering.
        try? await Task.sleep(for: .milliseconds(20))
        #expect(patches.count == 1)

        phone.transport.release()
        await eventually { patches.count == 2 }
        #expect(patches.map { $0["forgotten"] as? Bool } == [true, false])
    }

    @Test func aForgetTheServerDoesNotTakePutsTheRowBackAndSaysSo() async {
        await memory.load()
        serverAnswers { $0 == patchMushrooms ? .status(500) : nil }

        memory.forget(mushrooms)
        await eventually { memory.told.count == 2 }

        #expect(memory.told.map(\.subject) == ["mushrooms", "fish"])
        phone.undo.commitNow()
        await eventually { phone.undo.banner?.message == "Couldn't forget mushrooms. Try again." }
    }

    @Test func aLoadAnsweredWhileAForgetIsOnTheWireKeepsItHidden() async {
        await memory.load()
        phone.transport.holding = true
        memory.forget(mushrooms)
        await eventually { patches.count == 1 }

        let loading = Task { await memory.load() }
        await eventually { phone.transport.calls.last == get }
        phone.transport.release(only: get)
        await loading.value
        #expect(memory.told.map(\.subject) == ["fish"])

        phone.transport.release()
        await eventually { phone.transport.answered.last == patchMushrooms }
        #expect(memory.told.map(\.subject) == ["fish"])
    }
}
