import SwiftUI

/// Chef's week: five dinners on one card, three of yours and two new ideas,
/// each on its evening with a line of why. Nothing changes until Make the
/// list, which applies at once with Undo and Open, and never navigates by
/// itself. Not this week hides the card and teaches Chef nothing. On Home and
/// Discover; `scope` names the screen in each control's identifier.
struct WeekCard: View {
    let plan: WeekPlan
    let scope: String

    @Environment(Chef.self) private var chef
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                IconHeader(title: "Your week from \(plan.weekOf.longDate)", systemImage: "sparkles")
                    .font(.headline)
                Text(plan.note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(plan.meals) { meal in
                HStack(spacing: 10) {
                    Text(meal.day.dayShort)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .leading)
                    PictureRow(picture: meal.imageURL, title: meal.title) {
                        Text(meal.reason)
                            .lineLimit(2)
                    } mark: {
                        if meal.isNew {
                            Text("New")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.fill.tertiary, in: Capsule())
                                .fixedSize()
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("\(scope).week.meal.\(meal.day.iso)")
            }
            HStack {
                Spacer()
                Button("Not this week") { chef.week.skip() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("\(scope).week.skipButton")
                Button {
                    // Open goes to the list on whichever tab is showing when it is tapped.
                    chef.week.make { [navigation] in navigation.push(.plan($0), on: navigation.tab) }
                } label: {
                    HStack(spacing: 6) {
                        if chef.week.isMaking { ProgressView() }
                        Text("Make the list")
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("\(scope).week.makeButton")
            }
            .disabled(chef.week.isMaking)
        }
        .padding(.vertical, 4)
    }
}

/// Discover's offer to plan a week, shown while none is waiting.
struct PlanMyWeek: View {
    @Environment(Chef.self) private var chef

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.plus")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(
                chef.week.isPlanning
                    ? "Chef is planning your week. This takes a minute."
                    : "Let Chef plan five dinners for this week: three you love and two new ones."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                chef.week.planMyWeek()
            } label: {
                HStack(spacing: 6) {
                    if chef.week.isPlanning { ProgressView() }
                    Text("Plan my week")
                }
            }
            .buttonStyle(.bordered)
            .disabled(chef.week.isPlanning)
            .accessibilityIdentifier("discover.week.planButton")
        }
        .padding(16)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [5])))
    }
}
