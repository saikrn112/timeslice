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
    @State private var showResolved = false
    @State private var deviceLabels: [String: String] = [:]

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
                Text("Notes").font(.headline)
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
            HStack(spacing: 6) {
                TextField("Note something…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { add() }
                Button("Add") { add() }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    private func add() {
        _ = try? store.addFeedback(draft)
        draft = ""
        reload()
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
                Text(note.text)
                    .font(.callout)
                    .strikethrough(!note.isOpen, color: .secondary)
                    .foregroundStyle(note.isOpen ? Color.primary : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                // When and where it was written — usually the context that makes a terse note
                // make sense again a week later.
                Text(context(note))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
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
