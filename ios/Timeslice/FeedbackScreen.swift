import SwiftUI
import TimesliceCore
import TimesliceUI

/// Feedback, on the phone — a TAB, not a sheet behind Settings.
///
/// The feature and its sync arrived on the Mac; the phone had no entry point at all, which inverts the
/// point of it. `Feedback`'s own doc says notes exist because "the friction of *remember this, write it
/// down later on the Mac* loses most of it" — and the device you're holding when that happens is usually
/// this one. Reading them on the Mac and being unable to write them here is the wrong way round.
///
/// Everything is `IntervalStore`'s: `listFeedback`, `addFeedback`, `setFeedbackResolved`,
/// `deleteFeedback`, and they ride the existing sync payload. Nothing about notes is phone-specific
/// except this presentation.
struct FeedbackScreen: View {
    @ObservedObject private var model = TimerModel.shared
    @Environment(\.dismiss) private var dismiss

    @State private var notes: [Feedback] = []
    @State private var draft = ""
    @State private var filter: Filter = .open
    /// The note just marked done, so it can be put back. See `undoBar`.
    @State private var justResolved: Int64?
    @FocusState private var focused: Bool

    /// Open and Done as an explicit two-way filter, rather than the "Show done" link this had.
    ///
    /// A link that toggles a hidden state gave no hint that done notes still existed — which is exactly
    /// how marking one done read as losing it. A segmented control shows both halves up front, so "where
    /// did it go" answers itself.
    private enum Filter: String, CaseIterable, Identifiable {
        case open = "Open", done = "Done"
        var id: String { rawValue }
    }

    private var visible: [Feedback] {
        filter == .open ? notes.filter(\.isOpen) : notes.filter { !$0.isOpen }
    }

    var body: some View {
        NavigationStack {
            List {
                Section { composer }
                if let justResolved { undoBar(justResolved) }
                Section {
                    if visible.isEmpty {
                        Text(filter == .open ? "Nothing open" : "Nothing done yet")
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visible) { note in row(note) }
                    }
                } header: {
                    Picker("", selection: $filter) {
                        ForEach(Filter.allCases) { f in Text(f.rawValue).tag(f) }
                    }
                    .pickerStyle(.segmented)
                    .textCase(nil)
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: reload)
        }
    }

    /// Undo for the note just marked done.
    ///
    /// The reported problem: pressing done made a note vanish with no clean way back — you had to go to
    /// the Mac and un-done it there. Resolving was always reversible in the store
    /// (`setFeedbackResolved(resolved: false)`); the phone simply never offered it. This does, in place,
    /// while your attention is still on the row that disappeared.
    private func undoBar(_ id: Int64) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Marked done").font(Theme.caption)
            Spacer()
            Button("Undo") {
                setResolved(id: id, resolved: false)
                justResolved = nil
            }
            .font(Theme.caption.weight(.semibold))
        }
        .listRowBackground(Color.green.opacity(0.10))
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // `axis: .vertical` so a thought longer than one line doesn't scroll sideways inside a
            // single-line field, which is where notes get abandoned half-typed.
            TextField("Note something…", text: $draft, axis: .vertical)
                .font(Theme.rowTitle)
                .focused($focused)
                .lineLimit(1...5)
            Button {
                add()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(draft.trimmed.isEmpty ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmed.isEmpty)
        }
    }

    private func row(_ note: Feedback) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Tapping the circle resolves it — a note you've dealt with is the common action, and
            // burying it behind a swipe would make "done" harder than "delete".
            Button {
                setResolved(id: note.id, resolved: note.isOpen)
                // Arm undo only when marking DONE — un-doning needs no undo of its own.
                justResolved = note.isOpen ? note.id : nil
            } label: {
                Image(systemName: note.isOpen ? "circle" : "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(note.isOpen ? Color.secondary : Color.green)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(note.text)
                    .font(Theme.caption)
                    .strikethrough(!note.isOpen, color: .secondary)
                    .foregroundStyle(note.isOpen ? .primary : .secondary)
                HStack(spacing: 5) {
                    Text(note.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    // Which device it was written on — per `Feedback`, "where was I when I thought
                    // this" is usually the context. Only when more than one device is in play.
                    if let id = note.deviceID, let label = model.deviceLabels[id],
                       model.knownDevices.count > 1 {
                        Text("· \(label)")
                    }
                }
                .font(Theme.captionSmall)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                guard let store = model.storeIfLoaded else { return }
                try? store.deleteFeedback(id: note.id)
                reload()
            } label: {
                Image(systemName: "trash")
            }
        }
    }

    private func add() {
        guard let store = model.storeIfLoaded, !draft.trimmed.isEmpty else { return }
        _ = try? store.addFeedback(draft)
        draft = ""
        justResolved = nil
        Haptics.started()
        reload()
        // Publish promptly, so a note jotted here reaches the Mac on the next poll rather than
        // waiting for an opportunistic background refresh.
        SyncController.shared.publishSoon()
    }

    private func setResolved(id: Int64, resolved: Bool) {
        guard let store = model.storeIfLoaded else { return }
        try? store.setFeedbackResolved(id: id, resolved: resolved)
        Haptics.switched()
        reload()
        // Peers should see "done" too, or the note comes back open from the other device.
        SyncController.shared.publishSoon()
    }

    private func reload() {
        notes = (try? model.storeIfLoaded?.listFeedback()) ?? []
        model.refreshFeedbackCount()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
