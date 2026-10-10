import SwiftUI

/// One field for adding items. Understands "2 onions", "500g mince" and
/// "milk, eggs, bread"; a pasted list adds one item per line. Items appear at
/// once and nothing waits on the network.
struct QuickAddField: View {
    /// The screen's id prefix: the controls are `<screen>.quickAddField` and `<screen>.quickAddButton`.
    let screen: String
    var placeholder = "Add items, e.g. 2 onions, 500g mince"
    let onAdd: (String) -> Void

    @State private var text = ""

    var body: some View {
        HStack(spacing: 12) {
            // Vertical so a pasted list keeps its line breaks; Return then arrives as a newline.
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...4)
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .onChange(of: text) {
                    if text.contains(where: \.isNewline) { submit() }
                }
                .accessibilityIdentifier("\(screen).quickAddField")
            Button("Add", systemImage: "plus.circle.fill", action: submit)
                .labelStyle(.iconOnly)
                .font(.title2)
                .buttonStyle(.borderless)
                .disabled(text.trimmed.isEmpty)
                .accessibilityIdentifier("\(screen).quickAddButton")
        }
    }

    private func submit() {
        let entered = text.trimmed
        text = ""
        if !entered.isEmpty { onAdd(entered) }
    }
}
