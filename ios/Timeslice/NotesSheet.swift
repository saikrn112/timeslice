import SwiftUI
import TimesliceCore
import TimesliceUI

/// Notes, on the phone.
///
/// The feature and its sync arrived on the Mac; the phone had no entry point at all, which inverts the
/// point of it. `Feedback`'s own doc says notes exist because "the friction of *remember this, write it
/// down later on the Mac* loses most of it" — and the device you're holding when that happens is usually
/// this one. Reading them on the Mac and being unable to write them here is the wrong way round.
///
/// Everything is `IntervalStore`'s: `listFeedback`, `addFeedback`, `setFeedbackResolved`,
/// `deleteFeedback`, and they ride the existing sync payload. Nothing about notes is phone-specific
/// except this presentation.
struct NotesSheet: View {
    @ObservedObject private var model = TimerModel.shared
    @Environment(\.dismiss) private var dismiss

    @State private var notes: [Feedback] = []
    @State private var draft = ""
    @State private var showResolved = false
    @FocusState private var focused: Bool

    private var visible: [Feedback] {
        showResolved ? notes : notes.filter(\.isOpen)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    composer
                }
                if visible.isEmpty {
                    Text(showResolved ? "Nothing yet" : "No open notes")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(visible) { note in row(note) }
                    } header: {
                        HStack {
                            Text(showResolved ? "All notes" : "Open").font(Theme.captionSmall)
                            Spacer()
                            Button(showResolved ? "Hide done" : "Show done") {
                                showResolved.toggle()
                            }
                            .font(Theme.captionSmall)
                            .textCase(nil)
                        }
                    }
                }
            }
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: reload)
        }
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
                guard let store = model.storeIfLoaded else { return }
                try? store.setFeedbackResolved(id: note.id, resolved: note.isOpen)
                Haptics.switched()
                reload()
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
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func add() {
        guard let store = model.storeIfLoaded, !draft.trimmed.isEmpty else { return }
        _ = try? store.addFeedback(draft)
        draft = ""
        Haptics.started()
        reload()
        // Publish promptly, so a note jotted here reaches the Mac on the next poll rather than
        // waiting for an opportunistic background refresh.
        SyncController.shared.publishSoon()
    }

    private func reload() {
        notes = (try? model.storeIfLoaded?.listFeedback()) ?? []
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
