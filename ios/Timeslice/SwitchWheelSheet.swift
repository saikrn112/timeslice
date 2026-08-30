import AppIntents
import SwiftUI
import TimesliceCore
import TimesliceUI

/// The phone's answer to the Mac's revolver switcher.
///
/// The Mac's version works because you *hold* three modifiers, tap a key to advance, and **release**
/// to commit. A phone has neither a hold-and-tap nor a release, so the gesture can't be transplanted.
/// A wheel picker is the closest honest equivalent: `.pickerStyle(.wheel)` is natively the 3D drum,
/// and feeding it the shared recency order puts the current task at index 0 and the one you came from
/// at index 1 — so the very next item is the alt-tab target, same as one press of `\`.
///
/// Three things this gets deliberately right:
///
/// 1. **The order is FROZEN for the presentation.** Recency re-ranks after every switch; if the list
///    re-sorted live, the row under your thumb would move mid-scroll. Same reasoning as the Mac's
///    frozen `switcherOrder`.
/// 2. **Committing is explicit.** There's no "release" to commit on, and a mis-scroll that silently
///    switched tasks would cost a wrong interval — so scrolling only moves the selection, and a
///    button commits it.
/// 3. **It cannot live in the Dynamic Island.** Live Activities support buttons, toggles and links
///    via App Intents only — no gestures, no scroll views. The wheel needs the app foregrounded,
///    which is why the Action Button binding for it opens the app.
struct SwitchWheelSheet: View {
    @ObservedObject private var model = TimerModel.shared
    @Environment(\.dismiss) private var dismiss

    /// Captured once, in `init` — see point 1 above. Recomputing this as a derived property is the
    /// bug it exists to prevent.
    private let frozen: [Project]
    @State private var selection: Int64?

    init() {
        let ordered = TimerModel.shared.recencyOrdered
        frozen = ordered
        // Preselect index 1 — the task you came from. Landing on index 0 would mean the default
        // action is "switch to what you're already on", i.e. nothing.
        _selection = State(initialValue: (ordered.dropFirst().first ?? ordered.first)?.id)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if frozen.isEmpty {
                    ContentUnavailableView("No tasks", systemImage: "timer")
                } else {
                    Picker("Task", selection: $selection) {
                        ForEach(frozen, id: \.id) { task in
                            HStack(spacing: 8) {
                                Circle().fill(Color(hex: model.colorHex(for: task)))
                                    .frame(width: 10, height: 10)
                                Text(task.name)
                                if model.currentTaskID == task.id {
                                    Text("current").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .tag(Int64?.some(task.id))
                        }
                    }
                    .pickerStyle(.wheel)

                    Button {
                        if let selection { model.toggle(taskID: selection) }
                        dismiss()
                    } label: {
                        Text(commitLabel)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .disabled(selection == nil)
                }
            }
            .navigationTitle("Switch task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.height(320)])
    }

    /// Says what the button will actually do, because for the current task it pauses rather than
    /// switches — the same dual meaning `toggle` has everywhere else.
    private var commitLabel: String {
        guard let selection, let task = frozen.first(where: { $0.id == selection }) else {
            return "Switch"
        }
        if model.running?.projectID == selection { return "Pause \(task.name)" }
        return "Start \(task.name)"
    }
}

/// Action Button binding for people who switch more often than they pause: opens the app straight
/// onto the wheel instead of toggling.
///
/// Offered alongside `ToggleTimerIntent` rather than replacing it — §4.1 treats the plain toggle as
/// the 80% case. Which one the Action Button runs is the user's choice in Settings.
struct OpenSwitcherIntent: AppIntent {
    static var title: LocalizedStringResource = "Switch Timeslice Task"
    static var description = IntentDescription("Open Timeslice on the task switcher wheel.")
    /// Necessarily true: a wheel cannot be presented from the background, and Live Activities can't
    /// host one at all.
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        TimerModel.shared.requestSwitcher()
        return .result()
    }
}
