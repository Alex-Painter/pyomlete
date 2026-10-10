import SwiftUI

/// The one "Add to list" control, on Discover cards, the recipe page and the
/// Add result. The main part adds to the current list in one tap, because the
/// list you last used is nearly always the one you mean. The chevron opens a
/// picker for another list or a new one.
///
/// `add` says what is being added; this control only says where.
struct AddToListButton: View {
    /// The main button's accessibility id; the chevron's is `<identifier>.choose`.
    let identifier: String
    let add: (ListTarget) async -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isBusy = false
    @State private var isChoosing = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                run(.current)
            } label: {
                HStack(spacing: 6) {
                    if isBusy {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "text.badge.plus")
                    }
                    Text("Add to list")
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier(identifier)

            Rectangle()
                .fill(.white.opacity(0.3))
                .frame(width: 1, height: 24)

            Button {
                isChoosing = true
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Choose a list")
            .accessibilityIdentifier("\(identifier).choose")
        }
        .buttonStyle(.plain)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .background(.tint, in: RoundedRectangle(cornerRadius: 12))
        .opacity(isEnabled ? 1 : 0.5)
        .disabled(isBusy)
        .sheet(isPresented: $isChoosing) {
            ListPicker { run($0) }
        }
    }

    /// Not tied to this view: a card can scroll away, or its sheet close, while the request is out.
    private func run(_ target: ListTarget) {
        isBusy = true
        Task {
            await add(target)
            isBusy = false
        }
    }
}

private struct ListPicker: View {
    let onPick: (ListTarget) -> Void

    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let current = library.currentList?.id
        NavigationStack {
            List {
                ForEach(library.rows) { row in
                    Button {
                        pick(.list(row.id))
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name)
                                    .foregroundStyle(.primary)
                                Text("\(row.meals.count) meal\(row.meals.count == 1 ? "" : "s") · \(row.itemCount) item\(row.itemCount == 1 ? "" : "s")")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if row.id == current {
                                Label("Current", systemImage: "checkmark")
                                    .labelStyle(.titleAndIcon)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("listPicker.list.\(row.id.rawValue)")
                }
                Button("New list", systemImage: "plus") { pick(.new) }
                    .accessibilityIdentifier("listPicker.newListButton")
            }
            .navigationTitle("Add to which list?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("listPicker.cancelButton")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func pick(_ target: ListTarget) {
        dismiss()
        onPick(target)
    }
}
