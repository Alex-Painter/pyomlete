import SwiftUI

/// The running timers, shown on every step. The only thing in Cook that ticks,
/// and only while there is a chip to show: each chip reads the clock, and the
/// timers themselves are end dates.
struct TimerChips: View {
    let timers: [CookTimer]
    let onDismiss: (UUID) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { clock in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(timers.enumerated()), id: \.element.id) { position, timer in
                        chip(timer, at: clock.date, position: position)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func chip(_ timer: CookTimer, at now: Date, position: Int) -> some View {
        let isDone = timer.isDone(at: now)
        return HStack(spacing: 6) {
            Label(timer.chipText(at: now), systemImage: isDone ? "bell.fill" : "timer")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .accessibilityIdentifier("cook.timerChip.\(position)")
            Button("Dismiss timer", systemImage: "xmark") { onDismiss(timer.id) }
                .labelStyle(.iconOnly)
                .font(.footnote.weight(.bold))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .accessibilityIdentifier("cook.dismissTimer.\(position)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 2)
        .foregroundStyle(.white)
        .background(isDone ? AnyShapeStyle(.red) : AnyShapeStyle(.black.opacity(0.8)), in: Capsule())
        .accessibilityElement(children: .contain)
    }
}
