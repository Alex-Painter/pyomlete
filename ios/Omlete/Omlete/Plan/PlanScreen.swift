import SwiftUI

/// Plan: decide the week's dinners and build the list, on one screen.
///
/// A week list opens on its seven evenings, with the meal library under the
/// selected one, so a dinner is one tap; List shows the items. A plain list
/// keeps its meals and items, with the same library below them. Nothing here
/// changes mode on its own: checking items off or planning a meal never moves
/// you to Shop or Cook, which are buttons you press.
struct PlanScreen: View {
    let listID: ListID

    @Environment(Library.self) private var library
    @Environment(AppNavigation.self) private var navigation
    @Environment(ChefChat.self) private var chefChat
    @Environment(CalendarReader.self) private var calendar
    @Environment(\.scenePhase) private var scenePhase

    @State private var editing: ItemID?
    @State private var isRenaming = false
    @State private var showsGotIt = true
    @State private var focus = PlanFocus()
    @State private var query = MealLibraryQuery()
    @State private var today = PlanDate.today()
    /// What the calendar says about each evening of the week, read live and never written to the list.
    @State private var evenings: [PlanDate: CalendarDays.Evening] = [:]
    /// Busy evenings you chose to plan anyway, for this visit: the calendar only suggests.
    @State private var planAnyway: Set<PlanDate> = []

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
                content(list, in: store)
            }
        }
        .undoBanner(isCovered: navigation.immersive != nil)
        // Start shopping owns the bottom of this screen, and the tab bar would sit on top of it.
        .toolbarVisibility(.hidden, for: .tabBar)
        .task {
            library.markCurrent(listID)
            await store.refresh()
        }
        .task { await library.refreshRecipes() }
        .task { await calendar.watch() }
        .task(id: CalendarRead(days: store.replica.current?.days.map(\.date) ?? [], isOn: calendar.isOn, changes: calendar.changes)) {
            readCalendar(store.replica.current?.days ?? [])
        }
        .onChange(of: scenePhase) { if scenePhase == .active { calendar.refreshStatus() } }
        // Only the server can work out a meal's last day once a day is cleared,
        // so the library's "Last had" lines are fetched again after it has heard.
        .onChange(of: store.replica.base?.days) { old, _ in
            if old != nil { Task { await library.refreshRecipes() } }
        }
    }

    private func content(_ list: ListDetail, in store: ListStore) -> some View {
        ScrollViewReader { scroller in
            List {
                if store.syncStatus == .offline {
                    Label("Offline. Changes are saved on this phone and sync later.", systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
                if list.isWeek, let day = focus.day(in: list.days, today: today) {
                    if focus.view == .week {
                        week(list, day: day, in: store, scroller: scroller)
                    } else {
                        items(of: list, in: store)
                    }
                } else {
                    meals(of: list, in: store, scroller: scroller)
                    items(of: list, in: store)
                    MealLibrary(
                        heading: "Add meals", days: [], today: today, query: $query, addedValue: "On the list",
                        mark: { recipe in
                            store.mealsBeingAdded.contains(recipe.id) ? .busy : list.recipes.contains(recipe.id) ? .added : .add
                        },
                        onPick: { recipe in
                            if list.recipes.contains(recipe.id) {
                                store.removeMeal(recipe.id, title: recipe.title)
                            } else {
                                Task { await library.addMeal(recipe.id, title: recipe.title, to: .list(list.id)) }
                            }
                        })
                }
            }
            .accessibilityIdentifier("plan.list")
            .animation(.default, value: ListLayout(list, aisleOrder: library.aisles.order.names))
            .contentMargins(.bottom, 72, for: .scrollContent)
            .scrollDismissesKeyboard(.immediately)
            .safeAreaInset(edge: .top, spacing: 0) {
                if list.isWeek, let day = focus.day(in: list.days, today: today) {
                    weekHeader(list, selected: day.date)
                }
            }
            .onChange(of: list.days, initial: true) { focus.choose(in: list.days, today: today) }
            // A week's library opens on Best for this day; a plain list has no evening to rank for.
            .onChange(of: list.isWeek, initial: true) {
                if list.isWeek, query == MealLibraryQuery() { query.sort = .best }
                if !list.isWeek, query.sort == .best { query.sort = .notLately }
            }
        }
        .navigationTitle(list.name)
        // A large title would sit under the pinned week.
        .navigationBarTitleDisplayMode(list.isWeek ? .inline : .automatic)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Rename", systemImage: "pencil") { isRenaming = true }
                    .accessibilityIdentifier("plan.renameButton")
            }
            // Plan hides the tab bar, and "put it on this list" is what Chef is for here.
            ToolbarItem(placement: .topBarTrailing) {
                Button("Chef", systemImage: ChefSymbol.name) { chefChat.toggle() }
                    .accessibilityIdentifier("plan.chefButton")
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
                ItemSheet(item: item, aisles: library.aisles.order.names, units: library.units) {
                    store.update(id, $0)
                } onDelete: {
                    store.remove([id], saying: "Removed \(item.name)")
                }
            }
        }
        .sheet(isPresented: $isRenaming) {
            RenameListSheet(name: list.name) { store.rename($0) }
        }
    }

    /// Week and List, and on Week the strip of evenings, pinned above what scrolls.
    private func weekHeader(_ list: ListDetail, selected: PlanDate) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                viewButton("Week", .week, id: "plan.weekViewButton")
                viewButton("List", .list, id: "plan.listViewButton")
            }
            .padding(3)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
            if focus.view == .week {
                WeekStrip(days: list.days, selected: selected, today: today, title: { library.meal($0)?.title }, evenings: evenings) {
                    focus.select($0)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func viewButton(_ title: String, _ view: PlanFocus.View, id: String) -> some View {
        let isOn = focus.view == view
        return Button {
            focus.view = view
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isOn ? .primary : .secondary)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background {
                    if isOn {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color(.systemBackground))
                            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    @ViewBuilder
    private func week(_ list: ListDetail, day: PlanDay, in store: ListStore, scroller: ScrollViewProxy) -> some View {
        let dayMeals = Set(list.days.compactMap(\.plan.meal))
        let anyDay = list.recipes.filter { !dayMeals.contains($0) }.compactMap(library.meal)
        if !anyDay.isEmpty {
            Section("This week, any day") {
                mealsStrip(anyDay, cooked: list.cooked, planDay: day, in: store)
            }
        }

        Section {
            DayCard(
                day: day, meal: day.plan.meal.flatMap(library.meal),
                cooked: day.plan.meal.map(list.cooked.contains) ?? false,
                onCooked: { cooked in day.plan.meal.map { store.setCooked($0, cooked) } },
                onOpen: { navigation.push(.recipe($0), on: navigation.tab) },
                onCook: { navigation.startCooking($0, from: list.id) },
                onSwap: { withAnimation { scroller.scrollTo(MealLibrary.scrollID, anchor: .top) } },
                onClear: {
                    let title = day.plan.meal.flatMap(library.meal)?.title ?? "the meal"
                    store.clearDay(day.date, title: title)
                },
                onOut: { store.setOut(day.date, $0) },
                evening: evenings[day.date],
                planAnyway: planAnyway.contains(day.date),
                onPlanAnyway: { planAnyway.insert(day.date) })
        } header: {
            HStack {
                Text("\(day.date.dayLong) \(day.date.longDate)")
                Spacer()
                if day.date == today { Text("Today") }
                if day.plan != .out { quickButton(day, in: store) }
            }
        }

        MealLibrary(
            heading: "Pick for \(day.date.dayLong)", days: list.days, today: today, query: $query,
            addedValue: "Planned for \(day.date.dayLong)",
            mark: { $0.id == day.plan.meal ? .added : .add },
            onPick: { plan($0, on: day, in: store) },
            forDay: libraryDay(day, list: list))
    }

    /// A part-busy evening ranks like a quick night, without setting the day's
    /// own Quick night; a busy one shows no top three until Plan anyway.
    private func libraryDay(_ day: PlanDay, list: ListDetail) -> LibraryDay {
        var ranked = day
        if case .quick = evenings[day.date] { ranked.quick = true }
        return LibraryDay(
            day: ranked, items: list.items, varietyDays: library.planSettings.varietyDays,
            busy: isBusy(day.date) && day.plan.meal == nil)
    }

    /// The calendar says you're out, and you haven't chosen to plan anyway.
    private func isBusy(_ date: PlanDate) -> Bool {
        evenings[date]?.isBusy == true && !planAnyway.contains(date)
    }

    private func readCalendar(_ days: [PlanDay]) {
        guard calendar.isOn, let range = CalendarDays.weekRange(days) else {
            evenings = [:]
            return
        }
        evenings = CalendarDays.week(calendar.busy(from: range.start, to: range.end), days: days, dinner: .init())
    }

    /// A quick night ranks dinners over 30 minutes lower. It belongs to the
    /// evening, so it stays when a meal goes on.
    private func quickButton(_ day: PlanDay, in store: ListStore) -> some View {
        Button {
            store.setQuick(day.date, !day.quick)
        } label: {
            // "Quick", as the web says it at phone width; VoiceOver hears the whole name.
            Label("Quick", systemImage: "bolt.fill")
                .font(.footnote.weight(.semibold))
                .textCase(nil)
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
                .foregroundStyle(day.quick ? Color(.systemBackground) : Color(.secondaryLabel))
                .background(day.quick ? Color(.label) : Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Quick night")
        .accessibilityHint("Dinners over \(MealLibraryQuery.quickMinutes) minutes sink")
        .accessibilityAddTraits(day.quick ? .isSelected : [])
        .accessibilityIdentifier("plan.day.quickButton")
    }

    /// Tapping the meal already on the evening takes it off; any other goes on
    /// it, and the card moves on to the next evening still to plan.
    private func plan(_ meal: RecipeSummary, on day: PlanDay, in store: ListStore) {
        if day.plan.meal == meal.id {
            store.clearDay(day.date, title: meal.title)
            return
        }
        store.plan(meal.id, on: day.date)
        if case .ready(let list) = store.phase { focus.planned(day.date, days: list.days, skip: isBusy) }
    }

    private func mealsStrip(
        _ meals: [RecipeSummary], cooked: Set<RecipeID>, planDay: PlanDay?, in store: ListStore
    ) -> some View {
        MealsStrip(
            meals: meals, cooked: cooked, planDay: planDay?.date,
            onCooked: { store.setCooked($0.id, $1) },
            onPlan: { meal in if let planDay { plan(meal, on: planDay, in: store) } },
            onCook: { navigation.startCooking($0.id, from: listID) },
            onOpen: { navigation.push(.recipe($0.id), on: navigation.tab) },
            onRemove: { store.removeMeal($0.id, title: $0.title) })
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
    }

    private func meals(of list: ListDetail, in store: ListStore, scroller: ScrollViewProxy) -> some View {
        let meals = list.recipes.compactMap(library.meal)
        let showLibrary = { withAnimation { scroller.scrollTo(MealLibrary.scrollID, anchor: .top) } }
        return Section {
            if meals.isEmpty {
                Button("Pick this week's meals", systemImage: "plus", action: showLibrary)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("plan.pickMealsButton")
            } else {
                mealsStrip(meals, cooked: list.cooked, planDay: nil, in: store)
            }
        } header: {
            HStack {
                Text("Meals (\(meals.count))")
                Spacer()
                // With no meals the row below is the way in, and one is enough.
                if !meals.isEmpty {
                    Button(action: showLibrary) {
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
        }
    }

    @ViewBuilder
    private func items(of list: ListDetail, in store: ListStore) -> some View {
        let layout = ListLayout(list, aisleOrder: library.aisles.order.names)
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

/// What the calendar read depends on, so it reads again when any of it changes.
private struct CalendarRead: Equatable {
    let days: [PlanDate]
    let isOn: Bool
    let changes: Int
}
