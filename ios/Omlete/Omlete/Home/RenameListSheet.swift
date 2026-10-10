import SwiftUI

struct RenameListSheet: View {
    let onSave: (String) -> Void

    @State private var name: String
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(name: String, onSave: @escaping (String) -> Void) {
        _name = State(initialValue: name)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("e.g. Week of the 12th", text: $name)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .accessibilityIdentifier("rename.nameField")
            }
            .navigationTitle("Rename list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("rename.cancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .accessibilityIdentifier("rename.saveButton")
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { focused = true }
    }

    private func save() {
        onSave(name)
        dismiss()
    }
}
