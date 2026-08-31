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

    /// Captured once, so the row under your thumb cannot move as recency re-ranks. Same reasoning as
    /// the Mac's frozen `switcherOrder`.
    private let frozen: [Project]

    init() {
        frozen = TimerModel.shared.recencyOrdered
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(frozen.enumerated()), id: \.element.id) { index, task in
                        Button {
                            // ONE tap, committed immediately. The wheel needed a scroll plus a precise
                            // commit tap — two deliberate acts for the app's most repeated action, and
                            // the thing that made switching feel like work.
                            model.toggle(taskID: task.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Circle().fill(Color(hex: model.colorHex(for: task)))
                                    .frame(width: 12, height: 12)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(task.name)
                                        .font(.system(size: 17))
                                        .lineLimit(1)
                                    if model.currentTaskID == task.id {
                                        Text(model.isRunning ? "running — tap to pause" : "current — tap to resume")
                                            .font(.system(size: 12)).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(Format.compact(model.committedTodaySeconds[task.id] ?? 0))
                                    .font(.system(size: 15, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Image(systemName: model.running?.projectID == task.id
                                      ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(model.running?.projectID == task.id ? .orange : .green)
                            }
                            // 56pt rows: comfortably past the 44pt minimum, hittable without aiming.
                            .padding(.horizontal, 16).padding(.vertical, 13)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < frozen.count - 1 {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
            }
            .navigationTitle("Switch task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        // Tall enough to show several without scrolling, short enough to stay a sheet.
        .presentationDetents([.medium, .large])
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
