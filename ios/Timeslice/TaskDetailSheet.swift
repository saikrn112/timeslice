import SwiftUI
import TimesliceCore
import TimesliceUI

/// Rename, recolour, re-file, finish/archive, delete — the Mac's inline row actions and context menu,
/// gathered into a sheet because a phone row has no room for four icon buttons.
struct TaskDetailSheet: View {
    let task: Project

    @ObservedObject private var model = TimerModel.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var groupID: Int64?
    @State private var confirmingDelete = false
    @State private var newGroupName = ""
    @State private var addingGroup = false

    init(task: Project) {
        self.task = task
        _name = State(initialValue: task.name)
        _groupID = State(initialValue: task.taskProjectID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                        .onSubmit { commitName() }
                }

                Section("Project") {
                    // Inbox is the nil case, not a row in the table — same model as the Mac.
                    Picker("Project", selection: $groupID) {
                        Text("Inbox").tag(Int64?.none)
                        ForEach(model.groups) { group in
                            Text(group.name).tag(Int64?.some(group.id))
                        }
                    }
                    .onChange(of: groupID) { _, new in
                        model.setGroup(taskID: task.id, groupID: new)
                    }
                    Button("New project…") { addingGroup = true }
                }

                Section("Colour") {
                    // A task in a project takes a SHADE of the project's colour, so its own swatch
                    // is only used in Inbox. Say so rather than showing a control that does nothing.
                    if groupID == nil {
                        colorGrid
                    } else {
                        HStack {
                            Circle().fill(Color(hex: model.colorHex(for: task)))
                                .frame(width: 14, height: 14)
                            Text("Derived from the project's colour")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Today") {
                    LabeledContent("Tracked today",
                                   value: Format.compact(model.committedTodaySeconds[task.id] ?? 0))
                    LabeledContent("All time",
                                   value: Format.compact(model.committedAllTimeSeconds[task.id] ?? 0))
                }

                Section {
                    Button(task.finished ? "Mark unfinished" : "Mark finished") {
                        model.setFinished(taskID: task.id, !task.finished)
                        dismiss()
                    }
                    Button("Archive") {
                        model.setArchived(taskID: task.id, true)
                        dismiss()
                    }
                    Button("Delete task", role: .destructive) { confirmingDelete = true }
                } footer: {
                    Text("Finished tasks still count in Today and All Time, struck through. "
                         + "Archiving removes them from both.")
                }
            }
            .navigationTitle(task.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { commitName(); dismiss() }
                }
            }
            .alert("Delete “\(task.name)”?", isPresented: $confirmingDelete) {
                Button("Delete", role: .destructive) {
                    model.delete(taskID: task.id)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the task and all its recorded intervals. It cannot be undone.")
            }
            .alert("New project", isPresented: $addingGroup) {
                TextField("Name", text: $newGroupName)
                Button("Create") {
                    if let id = model.addGroup(named: newGroupName) {
                        groupID = id
                        model.setGroup(taskID: task.id, groupID: id)
                    }
                    newGroupName = ""
                }
                Button("Cancel", role: .cancel) { newGroupName = "" }
            }
        }
    }

    private var colorGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 10) {
            ForEach(Palette.colors, id: \.self) { hex in
                Circle()
                    .fill(Color(hex: hex))
                    .frame(height: 26)
                    .overlay {
                        if task.colorHex.caseInsensitiveCompare(hex) == .orderedSame {
                            Circle().stroke(Color.primary, lineWidth: 2)
                        }
                    }
                    .onTapGesture { model.setColor(taskID: task.id, hex: hex) }
            }
        }
        .padding(.vertical, 4)
    }

    private func commitName() {
        guard name != task.name else { return }
        model.rename(taskID: task.id, to: name)
    }
}
