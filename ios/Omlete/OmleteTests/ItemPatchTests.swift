import Foundation
import Testing
@testable import Omlete

struct ItemPatchTests {
    private func json(_ patch: ItemPatch) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(patch), as: UTF8.self)
    }

    private func decode(_ json: String) throws -> ItemPatch {
        try JSONDecoder().decode(ItemPatch.self, from: Data(json.utf8))
    }

    @Test func keepOmitsTheKey() throws {
        #expect(try json(ItemPatch()) == "{}")
        #expect(try json(.checked(true)) == #"{"checked":true}"#)
    }

    @Test func setNilIsJSONNull() throws {
        var patch = ItemPatch()
        patch.amount = .set(nil)
        patch.unit = .set(nil)
        #expect(try json(patch) == #"{"amount":null,"unit":null}"#)
    }

    @Test func setValueEncodesTheValue() throws {
        var patch = ItemPatch()
        patch.name = .set("leeks")
        patch.amount = .set(2)
        patch.unit = .set("kg")
        patch.category = .set("Bakery")
        #expect(try json(patch) == #"{"amount":2,"category":"Bakery","name":"leeks","unit":"kg"}"#)
    }

    @Test func roundTripsKeepNullAndValue() throws {
        var patch = ItemPatch()
        patch.amount = .set(nil)
        patch.unit = .set("tin")
        patch.checked = .set(false)

        let decoded = try decode(try json(patch))

        #expect(decoded == patch)
        #expect(decoded.name == .keep)
        #expect(decoded.amount == .set(nil))
    }

    @Test func mergingIsRightBiasedAndKeepNeverErases() {
        var first = ItemPatch()
        first.name = .set("leek")
        first.amount = .set(2)
        var second = ItemPatch()
        second.amount = .set(nil)
        second.checked = .set(true)

        let merged = first.merging(second)

        #expect(merged.name == .set("leek"))
        #expect(merged.amount == .set(nil))
        #expect(merged.checked == .set(true))
        #expect(merged.unit == .keep)
    }

    @Test func applyingChangesOnlyTheSetFields() {
        let item = ListItem(id: "1", name: "mince", amount: 500, unit: "g", category: "Meat", checked: false, sources: [])
        var patch = ItemPatch()
        patch.amount = .set(nil)
        patch.checked = .set(true)

        let patched = patch.applied(to: item)

        #expect(patched.amount == nil)
        #expect(patched.checked)
        #expect(patched.unit == "g")
        #expect(patched.name == "mince")
    }
}

struct ItemDraftTests {
    private let item = ListItem(id: "1", name: "mince", amount: 500, unit: "g", category: "Meat", checked: false, sources: [])

    @Test func anUntouchedDraftSendsNothing() {
        #expect(ItemDraft(item).patch(from: item).isEmpty)
    }

    @Test func clearingTheAmountAndUnitSendsNulls() {
        var draft = ItemDraft(item)
        draft.amount = nil
        draft.unit = ""

        let patch = draft.patch(from: item)

        #expect(patch.amount == .set(nil))
        #expect(patch.unit == .set(nil))
        #expect(patch.name == .keep)
        #expect(patch.category == .keep)
    }

    @Test func aBlankNameIsNotSent() {
        var draft = ItemDraft(item)
        draft.name = "  "
        draft.category = "Frozen"

        let patch = draft.patch(from: item)

        #expect(patch.name == .keep)
        #expect(patch.category == .set("Frozen"))
    }
}
