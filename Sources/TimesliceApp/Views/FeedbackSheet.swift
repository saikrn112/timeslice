import SwiftUI
import TimesliceCore

/// Read and clear the notes written on any device.
///
/// The Mac's job here is the *reading* end — the phone is where notes get written, mid-use, because
/// that's when you notice things. This is where you sit down and go through them.
struct FeedbackSheet: View {
    let store: IntervalStore
    var onClose: () -> Void

    @State private var notes: [Feedback] = []
    @State private var draft = ""
    /// Tag for the note being written. Defaults to the app you're in, since that's the likelier
    /// subject — one click retags it, which is cheaper than making every note start untagged.
    @State private var draftPlatform: FeedbackPlatform? = .macOS
    @State private var showResolved = false
    @State private var deviceLabels: [String: String] = [:]
    /// Note being reworded, and the draft text. Double-click to enter.
    @State private var editingID: Int64?
    @State private var editDraft = ""
    @State private var editPlatform: FeedbackPlatform?
    @FocusState private var editFocused: Bool

    private func reload() {
        notes = (try? store.listFeedback()) ?? []
        deviceLabels = (try? store.deviceLabels()) ?? [:]
    }

    private var visible: [Feedback] {
        showResolved ? notes : notes.filter(\.isOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Feedback").font(.headline)
                Text("\(notes.filter(\.isOpen).count) open")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("Show done", isOn: $showResolved)
                    .toggleStyle(.checkbox).font(.caption)
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            // Writing here too, not just on the phone: noticing something while looking at the list
            // of things you noticed is common enough that sending you elsewhere would be silly.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    TextField("Note something…", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .onSubmit { add() }
                    Button("Add") { add() }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                // Who has to act on this. Set while writing, when you know — asking later means
                // going back through a list of notes whose context you've lost.
                platformPicker(selection: $draftPlatform)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            Divider()

            if visible.isEmpty {
                Text(showResolved ? "Nothing yet" : "Nothing open")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(visible) { note in row(note) }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 560, height: 520)
        .onAppear { reload() }
    }

    private func beginEdit(_ note: Feedback) {
        editDraft = note.text
        editPlatform = note.platform
        editingID = note.id
        editFocused = true
    }

    private func commitEdit(_ note: Feedback) {
        // An empty draft is treated as "no change", not as deleting the note — the ✕ is for that.
        try? store.updateFeedback(id: note.id, text: editDraft)
        editingID = nil
        reload()
    }

    private func cancelEdit() {
        editingID = nil
        editDraft = ""
    }

    private func add() {
        _ = try? store.addFeedback(draft, platform: draftPlatform)
        draft = ""
        reload()
    }

    /// Three pills. Clicking the selected one clears it, so "no opinion" stays reachable without a
    /// fourth pill that means nothing.
    private func platformPicker(selection: Binding<FeedbackPlatform?>) -> some View {
        HStack(spacing: 4) {
            ForEach(FeedbackPlatform.allCases) { platform in
                let on = selection.wrappedValue == platform
                Button {
                    selection.wrappedValue = on ? nil : platform
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: platform.symbol).font(.system(size: 9))
                        Text(platform.label).font(.system(size: 10, weight: on ? .semibold : .regular))
                    }
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(on ? Color.accentColor.opacity(0.22)
                                                  : Color.secondary.opacity(0.10)))
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func row(_ note: Feedback) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                try? store.setFeedbackResolved(id: note.id, resolved: note.isOpen)
                reload()
            } label: {
                Image(systemName: note.isOpen ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(note.isOpen ? Color.secondary : Color.green)
            }
            .buttonStyle(.plain)
            .help(note.isOpen ? "Mark done" : "Reopen")

            // The id, so a note can be referred to by number when handing work to an agent.
            // Monospaced and fixed-width so the text column still lines up down the list.
            Text("#\(note.id)")
                .font(.system(size: 10, design: .monospaced)).monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 30, alignment: .trailing)
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 2) {
                if editingID == note.id {
                    TextField("", text: $editDraft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                        .lineLimit(1...6)
                        .focused($editFocused)
                        .onSubmit { commitEdit(note) }
                        // A TextField swallows onExitCommand, so Esc needs catching explicitly or
                        // there's no way out of the editor.
                        .onKeyPress(.escape) { cancelEdit(); return .handled }
                        // Clicking away saves rather than silently discarding what was typed.
                        .onChange(of: editFocused) { _, focused in
                            if !focused && editingID == note.id { commitEdit(note) }
                        }
                    // The tag is part of the note, so it's part of editing it. Applied on click
                    // rather than on commit: a pill that looks selected but isn't saved yet is a
                    // worse lie than a tag that's already written.
                    platformPicker(selection: Binding(
                        get: { editPlatform },
                        set: { new in
                            editPlatform = new
                            try? store.setFeedbackPlatform(id: note.id, new)
                            reload()
                        }))
                } else {
                    Text(note.text)
                        .font(.callout)
                        .strikethrough(!note.isOpen, color: .secondary)
                        .foregroundStyle(note.isOpen ? Color.primary : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        // Double-click to reword, the same gesture task and project rows use.
                        .onTapGesture(count: 2) { beginEdit(note) }
                }
                // When and where it was written — usually the context that makes a terse note
                // make sense again a week later.
                HStack(spacing: 5) {
                    if let platform = note.platform {
                        HStack(spacing: 3) {
                            Image(systemName: platform.symbol).font(.system(size: 8))
                            Text(platform.label).font(.system(size: 9, weight: .medium))
                        }
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                        .foregroundStyle(Color.accentColor)
                    }
                    Text(context(note))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)

            Button {
                try? store.deleteFeedback(id: note.id)
                reload()
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Delete — for something written by mistake")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func context(_ note: Feedback) -> String {
        var parts = [Self.stamp.string(from: note.createdAt)]
        if let id = note.deviceID {
            parts.append(deviceLabels[id] ?? TimeslicePaths.shortDeviceName(id))
        }
        return parts.joined(separator: " · ")
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM, HH:mm"; return f
    }()
}
