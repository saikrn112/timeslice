import AppKit
import SwiftUI
import TimesliceCore

/// Read and clear the notes written on any device.
///
/// The Mac's job here is the *reading* end — the phone is where notes get written, mid-use, because
/// that's when you notice things. This is where you sit down and go through them.
struct FeedbackSheet: View {
    let store: IntervalStore
    /// Half-written note, owned by the window controller so closing the window doesn't discard it.
    @ObservedObject var draft: FeedbackDraft
    var onClose: () -> Void

    @State private var notes: [Feedback] = []
    /// Show only notes about one app. nil is everything.
    @State private var filter: FeedbackPlatform?
    @State private var attachments: [String: [FeedbackAttachment]] = [:]
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
        attachments = (try? store.attachmentsByFeedbackUID()) ?? [:]
    }

    /// Notes are listed by row id but attachments hang off the uid, since that's what survives the
    /// trip between devices. One lookup keeps the id→uid mapping in one place.
    private func images(for note: Feedback) -> [FeedbackAttachment] {
        guard let uid = (try? store.feedbackUID(id: note.id)) ?? nil else { return [] }
        return attachments[uid] ?? []
    }

    private var visible: [Feedback] {
        notes.filter { (showResolved || $0.isOpen) && matchesFilter($0) }
    }

    /// A note tagged Both belongs to whichever app you're filtering for — that's what the tag
    /// means — so there's no separate Both filter to pick.
    private func matchesFilter(_ note: Feedback) -> Bool {
        guard let filter else { return true }
        return note.platform == filter || note.platform == .both
    }

    private func openCount(_ platform: FeedbackPlatform) -> Int {
        notes.filter { $0.isOpen && ($0.platform == platform || $0.platform == .both) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No title and no Done button: the window has both. Repeating them inside cost a
            // 16pt band of chrome that the list could use for another note.
            HStack {
                Text("\(notes.filter(\.isOpen).count) open")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("Show done", isOn: $showResolved)
                    .toggleStyle(.checkbox).font(.caption)
                Button {
                    // Pull, don't just re-read: if the note you're waiting for hasn't reached this
                    // device yet, reloading the same rows tells you nothing.
                    NotificationCenter.default.post(name: .syncNow, object: nil)
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Sync now and reload — for a note just written on another device")
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)

            Divider()

            // Writing here too, not just on the phone: noticing something while looking at the list
            // of things you noticed is common enough that sending you elsewhere would be silly.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    TextField("What's wrong?", text: $draft.text, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .onSubmit { add() }
                    Button("Add") { add() }
                        .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                HStack(spacing: 8) {
                    // Who has to act on this. Set while writing, when you know — asking later means
                    // going back through a list of notes whose context you've lost.
                    platformPicker(selection: $draft.platform)

                    Spacer()

                    // ⌘V goes to the text field, so pasting a picture needs its own button. ⌘⇧V is
                    // the shortcut, and dropping an image file on this panel works too.
                    Button {
                        if let png = ClipboardImage.png() { draft.pendingImages.append(png) }
                    } label: {
                        Label("Paste image", systemImage: "photo.on.rectangle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.link)
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .help("Paste a screenshot from the clipboard (⌘⇧V), or drop an image here")
                }

                if !draft.pendingImages.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(draft.pendingImages.enumerated()), id: \.offset) { idx, data in
                            thumbnail(data) { draft.pendingImages.remove(at: idx) }
                        }
                        Text("attached on Add").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            Divider()

            HStack(spacing: 5) {
                ForEach([FeedbackPlatform.macOS, .iOS]) { platform in
                    let on = filter == platform
                    pill(platform.label, symbol: platform.symbol,
                         trailing: "\(openCount(platform))", on: on) {
                        filter = on ? nil : platform
                    }
                }
                if filter != nil {
                    Button("Clear") { filter = nil }
                        .buttonStyle(.link).font(.system(size: 10))
                }
                Spacer()
                Text("\(visible.count) shown").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 7)

            Divider()

            if visible.isEmpty {
                Text(filter != nil ? "Nothing here for \(filter!.label)"
                                   : (showResolved ? "Nothing yet" : "Nothing open"))
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
        .frame(minWidth: 460, minHeight: 380)
        .onAppear { reload() }
        // Dropping a screenshot from the desktop is the other half of pasting one.
        .onDrop(of: [.fileURL, .png, .tiff], isTargeted: nil) { providers in
            ClipboardImage.png(from: providers) { png in
                if let png { draft.pendingImages.append(png) }
            }
            return true
        }
        // Clicking away closes the popover without the text field ever losing focus, so the
        // usual commit-on-blur doesn't fire. Commit here too or the edit is thrown away.
        .onDisappear {
            if let id = editingID, let note = notes.first(where: { $0.id == id }) {
                commitEdit(note)
            }
        }
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
        guard let id = (try? store.addFeedback(draft.text, platform: draft.platform)) ?? nil
        else { return }
        for png in draft.pendingImages { try? store.addAttachment(toFeedback: id, png: png) }
        draft.text = ""
        draft.pendingImages = []
        reload()
    }

    /// A pasted image, small. Clicking the ✕ drops it; clicking the image opens it full size in
    /// whatever normally opens PNGs.
    private func thumbnail(_ data: Data, onRemove: (() -> Void)? = nil,
                           open: (() -> Void)? = nil) -> some View {
        let image = NSImage(data: data)
        return ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    // A row can arrive before its bytes do; that's expected, not a failure.
                    Image(systemName: "photo").font(.system(size: 14)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.secondary.opacity(0.10))
                }
            }
            .frame(width: 56, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3)))
            .onTapGesture { open?() }

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
        }
    }

    /// Three pills. Clicking the selected one clears it, so "no opinion" stays reachable without a
    /// fourth pill that means nothing.
    private func platformPicker(selection: Binding<FeedbackPlatform?>) -> some View {
        HStack(spacing: 4) {
            ForEach(FeedbackPlatform.allCases) { platform in
                let on = selection.wrappedValue == platform
                pill(platform.label, symbol: platform.symbol, on: on) {
                    selection.wrappedValue = on ? nil : platform
                }
            }
        }
    }

    /// Shared by the tag picker and the filter bar: picking a tag and filtering by one are the
    /// same gesture on the same vocabulary, so they should be the same control.
    private func pill(_ title: String, symbol: String, trailing: String? = nil,
                      on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 9))
                Text(title).font(.system(size: 10, weight: on ? .semibold : .regular))
                if let trailing {
                    Text(trailing).font(.system(size: 9, design: .monospaced)).monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(on ? Color.accentColor.opacity(0.22)
                                          : Color.secondary.opacity(0.10)))
            .foregroundStyle(on ? Color.accentColor : Color.secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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

            // The SHARED number, not the row id: a note has to be called the same thing here and on
            // the phone, or "issue 47" doesn't identify anything. Monospaced and fixed-width so the
            // text column still lines up down the list.
            Text("#\(note.seq)")
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
                        // Double-click still works, but it isn't the affordance — see the pencil.
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

                let shots = images(for: note)
                if !shots.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(shots) { shot in
                            let url = store.fileURL(forAttachment: shot.uid)
                            thumbnail(shot.hasLocalFile ? (try? Data(contentsOf: url)) ?? Data()
                                                        : Data(),
                                      onRemove: editingID == note.id ? {
                                          try? store.deleteAttachment(id: shot.id)
                                          reload()
                                      } : nil,
                                      open: { if shot.hasLocalFile { NSWorkspace.shared.open(url) } })
                        }
                        // While editing, more can be added — the picture is part of the note.
                        if editingID == note.id {
                            Button {
                                if let png = ClipboardImage.png() {
                                    try? store.addAttachment(toFeedback: note.id, png: png)
                                    reload()
                                }
                            } label: {
                                Image(systemName: "plus").font(.system(size: 10))
                                    .frame(width: 26, height: 40)
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Paste another screenshot")
                        }
                    }
                }
            }

            Spacer(minLength: 4)

            // A visible button, not just a double-click. Double-click was the only way in and it
            // competes with text selection inside the same label — two clicks that land a few pixels
            // apart, or a shade too slow, select a word instead, which reads as the app ignoring you.
            Button {
                if editingID == note.id { commitEdit(note) } else { beginEdit(note) }
            } label: {
                Image(systemName: editingID == note.id ? "checkmark" : "pencil")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help(editingID == note.id ? "Save" : "Edit this note")

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
