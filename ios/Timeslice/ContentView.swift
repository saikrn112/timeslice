import SwiftUI
import TimesliceCore
import TimesliceUI

/// The container app: pick a task, see today's time, start/stop.
///
/// Deliberately minimal. The Mac app is where you analyse time; the phone's job is to answer "what
/// am I on" and to switch in one tap. Anything richer would be a second UI to keep in step for no
/// gain — the Dynamic Island is the real interface here.
struct ContentView: View {
    @ObservedObject private var model = TimerModel.shared
    @State private var newTaskName = ""
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            List {
                if let error = model.loadError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if model.tasks.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No tasks yet",
                            systemImage: "timer",
                            description: Text("Add a task, then assign the Action Button to "
                                              + "“Toggle Timeslice Timer” in Settings."))
                    }
                } else {
                    Section {
                        ForEach(model.tasks) { task in
                            TaskRow(task: task,
                                    colorHex: model.colorHex(for: task),
                                    seconds: model.todaySeconds[task.id] ?? 0,
                                    isRunning: model.running?.projectID == task.id,
                                    isCurrent: model.currentTaskID == task.id)
                                .contentShape(Rectangle())
                                .onTapGesture { model.toggle(taskID: task.id) }
                        }
                    } header: {
                        Text("Today")
                    } footer: {
                        if model.isRunning {
                            Text("Tap the running task to pause it.")
                        }
                    }
                }
            }
            .navigationTitle("Timeslice")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                }
                if model.currentTaskID != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Stop", role: .destructive) { model.stop() }
                    }
                }
            }
            .alert("New task", isPresented: $showingAdd) {
                TextField("Name", text: $newTaskName)
                Button("Add") {
                    model.addTask(named: newTaskName)
                    newTaskName = ""
                }
                Button("Cancel", role: .cancel) { newTaskName = "" }
            }
            .refreshable { model.reload() }
        }
        .onAppear { model.load() }
    }
}

private struct TaskRow: View {
    let task: Project
    let colorHex: String
    let seconds: TimeInterval
    let isRunning: Bool
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 10) {
            // The same swatch colour the Dynamic Island and the Mac timeline use.
            Circle()
                .fill(Color(hex: colorHex))
                .frame(width: 11, height: 11)
                .overlay {
                    if isRunning {
                        Circle().stroke(Color(hex: colorHex).opacity(0.45), lineWidth: 5)
                    }
                }

            Text(task.name)
                .fontWeight(isCurrent ? .semibold : .regular)
                .lineLimit(1)

            Spacer()

            if isRunning, let since = TimerModel.shared.running?.start {
                // Let SwiftUI's own timer text tick this rather than driving a 10fps clock: on a
                // phone the list is often not even on screen, and the island is the live surface.
                Text(timerInterval: since...Date.distantFuture, pauseTime: nil, countsDown: false)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Color(hex: colorHex))
            } else {
                Text(Format.compact(seconds))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(seconds > 0 ? .primary : .tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
