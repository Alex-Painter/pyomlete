import Foundation
import Testing
@testable import Omlete

struct ListLayoutTests {
    private func item(_ id: ItemID, _ category: String, checked: Bool = false) -> ListItem {
        ListItem(id: id, name: id.rawValue, amount: nil, unit: nil, category: category, checked: checked, sources: [])
    }

    private func list(_ items: [ListItem]) -> ListDetail {
        ListDetail(id: "list", name: "Week", recipes: [], items: items)
    }

    @Test func groupsUncheckedItemsInAisleOrder() {
        let layout = ListLayout(
            list([item("rice", "Pantry"), item("milk", "Dairy"), item("oats", "Pantry"), item("bread", "Bakery")]),
            aisleOrder: ["Bakery", "Dairy", "Pantry"])

        #expect(layout.aisles.map(\.name) == ["Bakery", "Dairy", "Pantry"])
        #expect(layout.aisles[2].items.map(\.id) == ["rice", "oats"])
        #expect(layout.remaining == 4)
    }

    @Test func unknownAislesComeLastInTheOrderTheyAppear() {
        let layout = ListLayout(
            list([item("a", "Zebra"), item("b", "Apple"), item("c", "Bakery")]),
            aisleOrder: ["Bakery"])

        #expect(layout.aisles.map(\.name) == ["Bakery", "Zebra", "Apple"])
    }

    @Test func anEmptyCategoryIsFiledUnderOther() {
        let layout = ListLayout(list([item("a", ""), item("b", "Other")]), aisleOrder: ["Other"])

        #expect(layout.aisles.map(\.name) == ["Other"])
        #expect(layout.aisles[0].items.map(\.id) == ["a", "b"])
    }

    @Test func checkedItemsLeaveTheirAisleForGotIt() {
        let layout = ListLayout(
            list([item("a", "Bakery", checked: true), item("b", "Bakery"), item("c", "Dairy", checked: true)]),
            aisleOrder: ["Bakery", "Dairy"])

        #expect(layout.aisles.map(\.name) == ["Bakery"])
        #expect(layout.got.map(\.id) == ["a", "c"])
        #expect(layout.remaining == 1)
    }

    @Test func aDragReportsTheAislesNewOrder() {
        let aisle = ListLayout(list([item("a", "X"), item("b", "X"), item("c", "X")]), aisleOrder: []).aisles[0]

        #expect(aisle.ids(moving: IndexSet(integer: 0), to: 3) == ["b", "c", "a"])
        #expect(aisle.ids(moving: IndexSet(integer: 2), to: 0) == ["c", "a", "b"])
        #expect(aisle.ids(moving: IndexSet(integer: 1), to: 1) == ["a", "b", "c"])
    }
}
