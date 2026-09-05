import SwiftUI
import TimesliceCore
import TimesliceUI

/// Create/rename/recolour/delete tags, and attach them to projects.
///
/// Tags attach to **projects**, and tasks inherit — the Mac exposes only project-level tagging too,
/// even though the schema supports task-level. Keeping the phone to the same surface avoids creating
/// task-level links the Mac can't show or remove.
struct TagEditorSheet: View {
    @ObservedObject private var model = TimerModel.shared
    @Environment(\.dismiss) private var dismiss

    @State private var newTagName = ""
    @State private var addingTag = false
    @State private var renaming: Tag?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if model.allTags.isEmpty {
                        Text("No tags yet").foregroundStyle(.secondary)
                    }
                    ForEach(model.allTags) { tag in
                        HStack(spacing: 8) {
                            Circle().fill(Color(hex: tag.colorHex)).frame(width: 10, height: 10)
                            Text(tag.name)
                            Spacer()
                            Text("\(projectCount(tag)) project\(projectCount(tag) == 1 ? "" : "s")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { delete(tag) }
                            Button("Rename") {
                                renaming = tag
                                renameText = tag.name
                            }.tint(.gray)
                        }
                    }
                } header: {
                    Text("Tags")
                } footer: {
                    Text("Deleting a tag detaches it from every project and removes any budget "
                         + "pointing at it.")
                }

                ForEach(model.groups) { group in
                    Section {
                        ForEach(model.allTags) { tag in
                            Button {
                                toggle(tag, on: group)
                            } label: {
                                HStack {
                                    Circle().fill(Color(hex: tag.colorHex))
                                        .frame(width: 9, height: 9)
                                    Text(tag.name).foregroundStyle(.primary)
                                    Spacer()
                                    if isAttached(tag, to: group) {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Circle().fill(Color(hex: group.colorHex)).frame(width: 7, height: 7)
                            Text(group.name)
                        }
                    }
                }
            }
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { addingTag = true } label: { Image(systemName: "plus") }
                }
            }
            .alert("New tag", isPresented: $addingTag) {
                TextField("Name", text: $newTagName)
                Button("Add") { add() }
                Button("Cancel", role: .cancel) { newTagName = "" }
            }
            .alert("Rename tag", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Rename") {
                    if let tag = renaming { rename(tag, to: renameText) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }

    // MARK: - Actions (all straight through to Core)

    private func add() {
        let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        newTagName = ""
        guard !name.isEmpty, let store = model.storeIfLoaded else { return }
        _ = try? store.upsertTag(name: name, colorHex: Palette.color(forIndex: model.allTags.count))
        model.reload()
    }

    private func rename(_ tag: Tag, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let store = model.storeIfLoaded else { return }
        try? store.renameTag(id: tag.id, name: trimmed)
        model.reload()
    }

    private func delete(_ tag: Tag) {
        // `deleteTag` detaches links and drops dependent targets inside one transaction — foreign
        // keys are ON, so doing it in the wrong order aborts the whole thing.
        try? model.storeIfLoaded?.deleteTag(id: tag.id)
        model.reload()
    }

    private func isAttached(_ tag: Tag, to group: TaskProject) -> Bool {
        model.tagsByGroup[group.id]?.contains(where: { $0.id == tag.id }) ?? false
    }

    private func projectCount(_ tag: Tag) -> Int {
        model.groups.filter { isAttached(tag, to: $0) }.count
    }

    private func toggle(_ tag: Tag, on group: TaskProject) {
        guard let store = model.storeIfLoaded else { return }
        if isAttached(tag, to: group) {
            try? store.removeTag(tag.id, from: .project(group.id))
        } else {
            try? store.addTag(tag.id, to: .project(group.id))
        }
        model.reload()
    }
}
