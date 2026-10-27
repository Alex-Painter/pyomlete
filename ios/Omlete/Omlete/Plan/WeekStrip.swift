import SwiftUI

/// The week at a glance: one button per evening, today marked, with a dot for
/// a meal, a ring for an evening still to plan and a moon for Out.
struct WeekStrip: View {
    let days: [PlanDay]
    let selected: PlanDate
    let today: PlanDate
    let title: (RecipeID) -> String?
    let onSelect: (PlanDate) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(days) { day in
                let isSelected = day.date == selected
                Button {
                    onSelect(day.date)
                } label: {
                    VStack(spacing: 3) {
                        Text(day.date == today ? "Today" : day.date.dayShort)
                            .font(.caption2)
                            .fontWeight(day.date == today ? .bold : .regular)
                            .foregroundStyle(day.date == today ? .primary : .secondary)
                        Text("\(day.date.day)")
                            .font(.body.weight(.semibold))
                        mark(day.plan)
                            .frame(height: 10)
                    }
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(.secondarySystemGroupedBackground))
                                .stroke(Color.accentColor, lineWidth: 2)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(describe(day))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("plan.day.\(day.date.iso)")
            }
        }
    }

    @ViewBuilder private func mark(_ plan: DayPlan) -> some View {
        switch plan {
        case .meal:
            Circle().fill(.yellow).frame(width: 8, height: 8)
        case .open:
            Circle().stroke(.secondary).frame(width: 8, height: 8)
        case .out:
            Image(systemName: "moon.fill")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private func describe(_ day: PlanDay) -> String {
        let when = "\(day.date == today ? "Today, " : "")\(day.date.dayLong) \(day.date.longDate)"
        let what = switch day.plan {
        case .meal(let recipe): title(recipe) ?? "meal planned"
        case .open: "nothing planned"
        case .out: "out"
        }
        return "\(when), \(what)"
    }
}
