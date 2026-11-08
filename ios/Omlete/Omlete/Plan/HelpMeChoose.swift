import SwiftUI

/// Narrow it down, where the top three were: one question at a time, answered
/// with one tap on a button sized by how many good meals sit behind it, until
/// three finalists are left. Back and Don't mind are always there, and the
/// peek row shows where it is heading; tapping a meal there ends the run.
/// The rules are `Narrow`'s; this view turns taps into its steps.
struct HelpMeChoose: View {
    /// The space the answers share; each gets its share of it, never under a tappable 56 points.
    static let answersHeight = 240.0
    static let minAnswer = 56.0

    let ranked: [FitScore.Ranked]
    let quickNight: Bool
    let mark: (RecipeSummary) -> MealLibrary.Mark
    let onPick: (RecipeSummary) -> Void
    let onClose: () -> Void

    @State private var state: Narrow.State?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = state ?? Narrow.start(ranked, quickNight: quickNight)
        let view = Narrow.next(state, ranked)
        Section {
            switch view {
            case .question(let question, let answers, let peek, let left):
                Text(question.prompt)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("plan.choose.question")
                ForEach(answers, id: \.values) { answer in
                    Button {
                        go(Narrow.answer(state, question, answer.values))
                    } label: {
                        HStack {
                            Text(answer.label)
                                .fontWeight(.semibold)
                            Spacer()
                            Text(answer.count == 1 ? "1 meal" : "\(answer.count) meals")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, minHeight: max(Self.minAnswer, answer.share * Self.answersHeight))
                        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("plan.choose.answer.\(answer.values.joined(separator: ","))")
                }
                controls(state, dontMind: question)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Leading now, \(left == 1 ? "1 meal" : "\(left) meals") left")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(peek, id: \.recipe.id) { meal in
                                Button(meal.recipe.title) { onPick(meal.recipe) }
                                    .buttonStyle(.bordered)
                                    .buttonBorderShape(.capsule)
                                    .accessibilityIdentifier("plan.choose.peek.\(meal.recipe.id.rawValue)")
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }

            case .finalists(let finalists):
                Text(finalists.count == 1 ? "Your finalist" : "Your \(finalists.count) finalists")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("plan.choose.finalistsHeading")
                ForEach(finalists, id: \.recipe.id) { meal in
                    MealPickCard(ranked: meal, mark: mark(meal.recipe), identifier: "plan.choose.finalist.\(meal.recipe.id.rawValue)") {
                        onPick(meal.recipe)
                    }
                }
                HStack(spacing: 16) {
                    backButton(state)
                    Button("Start over") { go(Narrow.start(ranked, quickNight: quickNight)) }
                        .fontWeight(.semibold)
                        .fixedSize()
                        .accessibilityIdentifier("plan.choose.startOverButton")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
            }
        } header: {
            header(state)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: state)
    }

    private func header(_ state: Narrow.State) -> some View {
        HStack(spacing: 6) {
            Text("Help me choose")
            ForEach(Narrow.answeredLabels(state), id: \.step.question) { chip in
                Text(chip.label)
                    .font(.footnote.weight(.medium))
                    .textCase(nil)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }
            Spacer()
            Button("Stop choosing", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("plan.choose.closeButton")
        }
        // One light tap per answer, on one view so a section of rows does not repeat it.
        .sensoryFeedback(.impact(weight: .light), trigger: state.steps.count) { old, new in new > old }
    }

    private func controls(_ state: Narrow.State, dontMind question: Narrow.Question) -> some View {
        HStack(spacing: 16) {
            backButton(state)
            Button("Don't mind") { go(Narrow.dontMind(state, question)) }
                .fontWeight(.semibold)
                .fixedSize()
                .accessibilityIdentifier("plan.choose.dontMindButton")
            Spacer()
        }
        .buttonStyle(.borderless)
        .frame(minHeight: 44)
    }

    private func backButton(_ state: Narrow.State) -> some View {
        Button("Back", systemImage: "arrow.left") { go(Narrow.back(state)) }
            .labelStyle(.titleAndIcon)
            .fontWeight(.semibold)
            .fixedSize()
            .disabled(state.steps.isEmpty)
            .accessibilityIdentifier("plan.choose.backButton")
    }

    private func go(_ next: Narrow.State) {
        state = Narrow.settle(next, ranked)
    }
}
