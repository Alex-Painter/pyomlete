import Foundation

/// What Plan shows of a week list apart from the list itself: the Week or
/// List view, and the evening selected.
nonisolated struct PlanFocus: Equatable, Sendable {
    enum View: Sendable {
        case week, list
    }

    var view = View.week
    /// nil until the week is first shown. Then it is held, so planning a meal
    /// or marking an evening Out never moves the card on its own.
    private(set) var selected: PlanDate?

    /// The selected evening, or the one Plan would choose, until it has chosen.
    func day(in days: [PlanDay], today: PlanDate) -> PlanDay? {
        let date = selected ?? Week.defaultDay(days, today: today)
        return days.first { $0.date == date } ?? days.first
    }

    mutating func choose(in days: [PlanDay], today: PlanDate) {
        if selected == nil { selected = Week.defaultDay(days, today: today) }
    }

    mutating func select(_ date: PlanDate) {
        selected = date
    }

    /// A meal went on `date`: move on to the next evening still to plan.
    mutating func planned(_ date: PlanDate, days: [PlanDay]) {
        selected = Week.nextOpenDay(days, from: date)
    }
}
