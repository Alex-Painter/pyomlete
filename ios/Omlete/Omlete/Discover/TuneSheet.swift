import SwiftUI

/// Steers the next batch of ideas. Taste itself is learned from ratings and
/// lists, so this is the only thing here to set, and it is remembered.
struct TuneSheet: View {
    /// A batch is already being found, and a second would be ignored.
    let isBusy: Bool
    let onApply: (TuneSettings) -> Void

    @State private var draft: TuneSettings
    @Environment(\.dismiss) private var dismiss

    init(settings: TuneSettings, isBusy: Bool, onApply: @escaping (TuneSettings) -> Void) {
        _draft = State(initialValue: settings)
        self.isBusy = isBusy
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    chips(TuneSettings.Diet.allCases, selected: draft.diet, title: \.title, id: "tune.diet") { draft.diet = $0 }
                } header: {
                    Text("Diet")
                }
                Section("Effort") {
                    chips(TuneSettings.Effort.allCases, selected: draft.effort, title: \.title, id: "tune.effort") {
                        draft.effort = $0
                    }
                }
                Section("Anything else") {
                    TextField("e.g. use up spinach, kid-friendly, more fish", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("tune.notesField")
                }
                Section {
                    Button {
                        dismiss()
                        onApply(draft)
                    } label: {
                        Text("Get ideas")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isBusy)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("tune.applyButton")
                } footer: {
                    Text("Your ratings and lists are always taken into account.")
                }
            }
            .navigationTitle("Tune suggestions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("tune.cancelButton")
                }
            }
        }
        .presentationDetents([.large])
    }

    private func chips<Choice: Hashable & RawRepresentable<String>>(
        _ choices: [Choice], selected: Choice, title: KeyPath<Choice, String>, id: String, pick: @escaping (Choice) -> Void
    ) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(choices, id: \.self) { choice in
                    Button(choice[keyPath: title]) { pick(choice) }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(choice == selected ? .accentColor : .secondary)
                        .accessibilityAddTraits(choice == selected ? .isSelected : [])
                        .accessibilityIdentifier("\(id).\(choice.rawValue)")
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}
