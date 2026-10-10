import SwiftUI

struct CookStep: View {
    let page: CookSession.StepPage
    let onStartTimer: (DetectedTimer) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(page.text)
                    .font(.title)
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !page.timers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(page.timers) { found in
                            Button {
                                onStartTimer(found)
                            } label: {
                                Label("Start \(formatClock(found.seconds)) timer", systemImage: "timer")
                                    .fontWeight(.semibold)
                                    .monospacedDigit()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .accessibilityIdentifier("cook.startTimer.\(found.id)")
                        }
                    }
                }

                if !page.ingredients.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("For this step")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(page.ingredients) { line in
                            IngredientRow(line: line)
                        }
                    }
                    .padding(16)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(20)
        }
        // A new step starts scrolled to its top.
        .id(page.number)
    }
}
