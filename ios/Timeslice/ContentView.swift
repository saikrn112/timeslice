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
                                    committedSeconds: model.committedTodaySeconds[task.id] ?? 0,
                                    liveOrigin: model.liveOrigin(for: task.id),
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
    /// Today's seconds from closed intervals. The live run is added by `liveOrigin`, not by this.
    let committedSeconds: TimeInterval
    /// Non-nil only for the running task: the backdated instant to tick today's total from.
    let liveOrigin: Date?
    let isCurrent: Bool

    private var isRunning: Bool { liveOrigin != nil }

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

            if let liveOrigin {
                // TODAY'S TOTAL, ticking — committed base plus the live run, which is what the Mac
                // shows. Counting from the run's own start instead would make this number collapse
                // to zero on every task switch, reading as a reset rather than a context switch.
                //
                // Ticked by SwiftUI from a date rather than by a 10fps clock of our own: on a phone
                // this list is usually not even on screen, and the island is the live surface.
                Text(timerInterval: liveOrigin...Date.distantFuture,
                     pauseTime: nil, countsDown: false)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Color(hex: colorHex))
            } else {
                Text(Format.compact(committedSeconds))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(committedSeconds > 0 ? .primary : .tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
