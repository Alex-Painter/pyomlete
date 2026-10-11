import SwiftUI

/// Plan: the meals and the items of one list, on one screen. Nothing here
/// changes mode on its own: checking items off or adding a meal never moves
/// you to Shop, which is a button you press.
struct PlanScreen: View {
    let listID: ListID

    @Environment(Library.self) private var library
    @Environment(AppNavigation.self) private var navigation

    @State private var editing: ItemID?
    @State private var isRenaming = false
    @State private var isAddingMeals = false
    @State private var showsGotIt = true

    var body: some View {
        let store = library.list(listID)
        Group {
            switch store.phase {
            case .loading:
                ProgressView()
            case .gone:
                ContentUnavailableView("This list has been deleted.", systemImage: "trash")
            case .unavailable:
                ContentUnavailableView {
                    Label("Couldn't reach Omlete. Check your connection.", systemImage: "wifi.slash")
                } actions: {
                    Button("Try again") {
                        Task { await store.refresh() }
                    }
                    .accessibilityIdentifier("plan.retryButton")
                }
            case .ready(let list):
                items(of: list, in: store)
            }
        }
        .undoBanner(isCovered: navigation.immersive != nil || isAddingMeals)
        // Start shopping owns the bottom of this screen, and the tab bar would sit on top of it.
        .toolbarVisibility(.hidden, for: .tabBar)
        .task {
            library.markCurrent(listID)
            await store.refresh()
        }
    }

    private func items(of list: ListDetail, in store: ListStore) -> some View {
        let layout = ListLayout(list, aisleOrder: library.aisleOrder)
        let meals = list.recipes.compactMap(library.meal)
        return List {
            if store.syncStatus == .offline {
                Label("Offline. Changes are saved on this phone and sync later.", systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }

            Section {
                if meals.isEmpty {
                    Button("Pick this week's meals", systemImage: "plus") { isAddingMeals = true }
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("plan.pickMealsButton")
                } else {
                    MealsStrip(meals: meals) {
                        store.removeMeal($0.id, title: $0.title)
                    } onCook: {
                        navigation.startCooking($0.id)
                    }
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }
            } header: {
                HStack {
                    Text("Meals (\(meals.count))")
                    Spacer()
                    Button {
                        isAddingMeals = true
                    } label: {
                        // Laid out by hand: in a List header a Label leaves a wide gutter after its icon.
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                            Text("Add meals")
                        }
                    }
                    .font(.subheadline)
                    .accessibilityIdentifier("plan.addMealsButton")
                }
            }

            Section("Items (\(layout.remaining))") {
                QuickAddField(screen: "plan") { store.add($0) }
                if list.items.isEmpty {
                    Text("Add meals and their ingredients appear here, or type items above. Paste a whole list if you have one.")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(layout.aisles) { aisle in
                Section(aisle.name) {
                    ForEach(aisle.items) { item in
                        row(item, in: store)
                    }
                    .onMove { store.reorder(aisle.name, moving: $0, to: $1) }
                }
            }

            if !layout.got.isEmpty {
                Section {
                    if showsGotIt {
                        ForEach(layout.got) { item in
                            row(item, in: store)
                        }
                    }
                } header: {
                    gotItHeader(layout.got, in: store)
                }
            }
        }
        .accessibilityIdentifier("plan.list")
        .animation(.default, value: layout)
        .contentMargins(.bottom, 72, for: .scrollContent)
        .navigationTitle(list.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Rename", systemImage: "pencil") { isRenaming = true }
                    .accessibilityIdentifier("plan.renameButton")
            }
            ToolbarItem(placement: .bottomBar) {
                Button {
                    navigation.startShopping(listID)
                } label: {
                    // A toolbar shows a Label as its icon alone, and this is the screen's main action.
                    HStack(spacing: 6) {
                        Image(systemName: "cart")
                        Text("Start shopping")
                    }
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("plan.startShoppingButton")
            }
        }
        .sheet(item: $editing) { id in
            if let item = list.items.first(where: { $0.id == id }) {
                ItemSheet(item: item, aisles: library.aisleOrder, units: library.units) {
                    store.update(id, $0)
                } onDelete: {
                    store.remove([id], saying: "Removed \(item.name)")
                }
            }
        }
        .sheet(isPresented: $isAddingMeals) {
            MealsSheet(list: list, store: store)
        }
        .sheet(isPresented: $isRenaming) {
            RenameListSheet(name: list.name) { store.rename($0) }
        }
    }

    private func row(_ item: ListItem, in store: ListStore) -> some View {
        ItemRow(item: item, identifier: "plan.itemRow.\(item.id.rawValue)") {
            store.setChecked(item.id, !item.checked)
        } onEdit: {
            editing = item.id
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                store.remove([item.id], saying: "Removed \(item.name)")
            }
        }
        .swipeActions(edge: .leading) {
            Button("Edit", systemImage: "pencil") { editing = item.id }
        }
    }

    private func gotItHeader(_ got: [ListItem], in store: ListStore) -> some View {
        HStack {
            Button {
                withAnimation { showsGotIt.toggle() }
            } label: {
                Label("Got it (\(got.count))", systemImage: showsGotIt ? "chevron.up" : "chevron.down")
                    .labelStyle(.titleAndIcon)
            }
            .accessibilityIdentifier("plan.gotItToggle")
            Spacer()
            Button("Clear checked") {
                store.remove(got.map(\.id), saying: "Cleared \(got.count) checked item\(got.count == 1 ? "" : "s")")
            }
            .accessibilityIdentifier("plan.clearCheckedButton")
        }
        .font(.subheadline)
    }
}
