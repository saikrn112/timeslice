import PhotosUI
import SwiftUI
import TimesliceCore
import TimesliceUI
import UIKit

/// Feedback, on the phone — a TAB, not a sheet behind Settings.
///
/// The feature and its sync arrived on the Mac; the phone had no entry point at all, which inverts the
/// point of it. `Feedback`'s own doc says notes exist because "the friction of *remember this, write it
/// down later on the Mac* loses most of it" — and the device you're holding when that happens is usually
/// this one. Reading them on the Mac and being unable to write them here is the wrong way round.
///
/// Everything is `IntervalStore`'s: `listFeedback`, `addFeedback`, `setFeedbackPlatform`,
/// `updateFeedback`, `addAttachment`, `setFeedbackResolved`, `deleteFeedback`, and they ride the
/// existing sync payload. Nothing about feedback is phone-specific except this presentation — which is
/// the point: the two screens have to stay the same feature, not two that drifted apart.
struct FeedbackScreen: View {
    @ObservedObject private var model = TimerModel.shared
    @Environment(\.dismiss) private var dismiss

    @State private var notes: [Feedback] = []
    @State private var draft = ""
    /// Which app the note is about. Defaults to iOS here for the same reason the Mac defaults to
    /// macOS: it's the likelier subject of something you noticed just now, and one tap changes it.
    @State private var draftPlatform: FeedbackPlatform? = .iOS
    /// Images picked before the note exists. They can't attach to a row that hasn't been written, so
    /// they wait here and land when the note is sent.
    @State private var pendingImages: [Data] = []
    @State private var picking: [PhotosPickerItem] = []
    @State private var filter: Filter = .open
    /// Show only feedback about one app, mirroring the Mac's filter pills. nil is everything.
    @State private var platformFilter: FeedbackPlatform?
    /// The note just marked done, so it can be put back. See `undoBar`.
    @State private var justResolved: Int64?
    /// Note being reworded, and its text. Entered from the pencil, not a long-press or a swipe.
    @State private var editingID: Int64?
    @State private var editDraft = ""
    @State private var attachments: [String: [FeedbackAttachment]] = [:]
    /// Image being looked at full size.
    @State private var viewing: ViewedImage?
    @FocusState private var focused: Bool
    @FocusState private var editFocused: Bool

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
        notes.filter { (filter == .open) == $0.isOpen && matchesPlatform($0) }
    }

    /// A note tagged Both belongs to whichever app you're filtering for — that's what the tag means —
    /// so there's no third pill for it, exactly as on the Mac.
    private func matchesPlatform(_ note: Feedback) -> Bool {
        guard let platformFilter else { return true }
        return note.platform == platformFilter || note.platform == .both
    }

    var body: some View {
        NavigationStack {
            List {
                Section { composer }
                if let justResolved { undoBar(justResolved) }
                Section {
                    if visible.isEmpty {
                        Text(emptyMessage)
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visible) { note in row(note) }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $filter) {
                            ForEach(Filter.allCases) { f in Text(f.rawValue).tag(f) }
                        }
                        .pickerStyle(.segmented)
                        platformFilterBar
                    }
                    .textCase(nil)
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("Feedback")
            .navigationBarTitleDisplayMode(.inline)
            // The keyboard had no way down: this is a List, so there's nothing to tap that isn't a
            // row, and the composer's field keeps focus until something takes it away. Dragging the
            // list now dismisses it, and the toolbar above the keys has an explicit Done.
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = false; editFocused = false }
                }
            }
            .onAppear(perform: reload)
            .photosPicker(isPresented: $showPicker, selection: $picking,
                          maxSelectionCount: 4, matching: .images)
            .onChange(of: picking) { _, items in Task { await absorb(items) } }
            .sheet(item: $viewing) { item in
                FullSizeImage(image: item.image) { viewing = nil }
            }
        }
    }

    private var emptyMessage: String {
        if let platformFilter { return "Nothing here for \(platformFilter.label)" }
        return filter == .open ? "Nothing open" : "Nothing done yet"
    }

    /// Two pills with counts, the same vocabulary and the same behaviour as the Mac's filter bar.
    private var platformFilterBar: some View {
        HStack(spacing: 6) {
            ForEach([FeedbackPlatform.macOS, .iOS]) { platform in
                let on = platformFilter == platform
                let count = notes.filter {
                    (filter == .open) == $0.isOpen
                        && ($0.platform == platform || $0.platform == .both)
                }.count
                pill(platform.label, symbol: platform.symbol, trailing: "\(count)", on: on) {
                    platformFilter = on ? nil : platform
                    Haptics.switched()
                }
            }
            Spacer()
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                // `axis: .vertical` so a thought longer than one line doesn't scroll sideways inside a
                // single-line field, which is where notes get abandoned half-typed.
                TextField("What's wrong?", text: $draft, axis: .vertical)
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

            HStack(spacing: 6) {
                // Who has to act on this, set while writing — asking later means going back through
                // a list of notes whose context you've lost.
                ForEach(FeedbackPlatform.allCases) { platform in
                    let on = draftPlatform == platform
                    pill(platform.label, symbol: platform.symbol, on: on) {
                        draftPlatform = on ? nil : platform
                        Haptics.switched()
                    }
                }
                Spacer()
                // A screenshot says in a glance what three lines of typing on a phone keyboard don't.
                // The photo library is where a screenshot already is; the clipboard is where it is if
                // you just took one and copied it.
                Button { showPicker = true } label: {
                    Image(systemName: "photo.badge.plus").font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                if UIPasteboard.general.hasImages {
                    Button {
                        if let data = pastedImage() { pendingImages.append(data) }
                    } label: {
                        Image(systemName: "doc.on.clipboard").font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }

            if !pendingImages.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(pendingImages.enumerated()), id: \.offset) { idx, data in
                        thumbnail(UIImage(data: data)) { pendingImages.remove(at: idx) }
                    }
                    Text("sent with the note")
                        .font(Theme.captionSmall).foregroundStyle(.tertiary)
                }
            }
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

            VStack(alignment: .leading, spacing: 4) {
                if editingID == note.id {
                    TextField("", text: $editDraft, axis: .vertical)
                        .font(Theme.caption)
                        .lineLimit(1...8)
                        .focused($editFocused)
                        .textFieldStyle(.roundedBorder)
                    // The tag is part of the note, so it's editable wherever the note is.
                    HStack(spacing: 6) {
                        ForEach(FeedbackPlatform.allCases) { platform in
                            let on = note.platform == platform
                            pill(platform.label, symbol: platform.symbol, on: on) {
                                setPlatform(id: note.id, on ? nil : platform)
                            }
                        }
                    }
                } else {
                    Text(note.text)
                        .font(Theme.caption)
                        .strikethrough(!note.isOpen, color: .secondary)
                        .foregroundStyle(note.isOpen ? .primary : .secondary)
                }

                HStack(spacing: 5) {
                    if let platform = note.platform, editingID != note.id {
                        HStack(spacing: 3) {
                            Image(systemName: platform.symbol).font(.system(size: 8))
                            Text(platform.label).font(.system(size: 9, weight: .medium))
                        }
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                        .foregroundStyle(Color.accentColor)
                    }
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

                let shots = images(for: note)
                if !shots.isEmpty || editingID == note.id {
                    HStack(spacing: 6) {
                        ForEach(shots) { shot in
                            let data = shot.hasLocalFile
                                ? try? Data(contentsOf: store?.fileURL(forAttachment: shot.uid)
                                    ?? URL(fileURLWithPath: "/dev/null"))
                                : nil
                            thumbnail(data.flatMap(UIImage.init(data:)),
                                      onRemove: editingID == note.id ? {
                                          try? store?.deleteAttachment(id: shot.id)
                                          reload()
                                      } : nil,
                                      open: { viewing = data.flatMap(UIImage.init(data:))
                                                            .map(ViewedImage.init) })
                        }
                        if editingID == note.id {
                            Button { attachTo = note.id; showPicker = true } label: {
                                Image(systemName: "photo.badge.plus")
                                    .font(.system(size: 13))
                                    .frame(width: 40, height: 40)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            // A pencil, not a double-tap or a long-press: on a phone both are guesses, and a
            // long-press on a List row already means "select". Same control as the Mac's.
            Button {
                if editingID == note.id { commitEdit(note) } else { beginEdit(note) }
            } label: {
                Image(systemName: editingID == note.id ? "checkmark.circle" : "pencil")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .foregroundStyle(editingID == note.id ? Color.accentColor : Color.secondary)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                try? store?.deleteFeedback(id: note.id)
                if editingID == note.id { editingID = nil }
                reload()
            } label: {
                Image(systemName: "trash")
            }
        }
    }

    // MARK: - Pills and thumbnails

    /// Same pill the Mac uses for tagging and filtering, because they're the same gesture over the
    /// same vocabulary — just sized for a thumb.
    private func pill(_ title: String, symbol: String, trailing: String? = nil,
                      on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(title).font(.system(size: 11, weight: on ? .semibold : .regular))
                if let trailing {
                    Text(trailing).font(.system(size: 10, design: .monospaced)).monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(on ? Color.accentColor.opacity(0.22)
                                          : Color.secondary.opacity(0.12)))
            .foregroundStyle(on ? Color.accentColor : Color.secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func thumbnail(_ image: UIImage?, onRemove: (() -> Void)? = nil,
                           open: (() -> Void)? = nil) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    // A manifest row can arrive before its bytes; that's expected, not a failure.
                    Image(systemName: "photo").font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.secondary.opacity(0.12))
                }
            }
            .frame(width: 54, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .onTapGesture { open?() }

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
            }
        }
    }

    // MARK: - Images

    /// Whether the picker is up, and what it's picking for: a note being edited, or the composer.
    @State private var showPicker = false
    @State private var attachTo: Int64?

    private func pastedImage() -> Data? {
        guard let image = UIPasteboard.general.image, let cg = image.cgImage else { return nil }
        return ImageBytes.png(from: cg)
    }

    /// PhotosPicker hands back opaque items; the bytes have to be requested. Downscaled through the
    /// shared `ImageBytes` so a picture picked here is stored exactly as one pasted on the Mac.
    private func absorb(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        var pngs: [Data] = []
        for item in items {
            guard let raw = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: raw), let cg = image.cgImage,
                  let png = ImageBytes.png(from: cg)
            else { continue }
            pngs.append(png)
        }
        await MainActor.run {
            if let id = attachTo {
                // Straight onto an existing note — no "send" step to wait for.
                for png in pngs { try? store?.addAttachment(toFeedback: id, png: png) }
                attachTo = nil
                reload()
                SyncController.shared.publishSoon()
            } else {
                pendingImages.append(contentsOf: pngs)
            }
            picking = []
        }
    }

    // MARK: - Store

    private var store: IntervalStore? { model.storeIfLoaded }

    /// Notes are listed by row id but attachments hang off the note's uid, since that's what survives
    /// the trip between devices.
    private func images(for note: Feedback) -> [FeedbackAttachment] {
        guard let uid = (try? store?.feedbackUID(id: note.id)) ?? nil else { return [] }
        return attachments[uid] ?? []
    }

    private func add() {
        guard let store, !draft.trimmed.isEmpty else { return }
        guard let id = (try? store.addFeedback(draft, platform: draftPlatform)) ?? nil else { return }
        for png in pendingImages { try? store.addAttachment(toFeedback: id, png: png) }
        draft = ""
        pendingImages = []
        justResolved = nil
        focused = false
        Haptics.started()
        reload()
        // Publish promptly, so a note jotted here reaches the Mac on the next poll rather than
        // waiting for an opportunistic background refresh.
        SyncController.shared.publishSoon()
    }

    private func beginEdit(_ note: Feedback) {
        editDraft = note.text
        editingID = note.id
        editFocused = true
    }

    private func commitEdit(_ note: Feedback) {
        // An empty draft means "no change", not "delete the note" — the swipe is for that.
        try? store?.updateFeedback(id: note.id, text: editDraft)
        editingID = nil
        editFocused = false
        reload()
        SyncController.shared.publishSoon()
    }

    private func setPlatform(id: Int64, _ platform: FeedbackPlatform?) {
        try? store?.setFeedbackPlatform(id: id, platform)
        Haptics.switched()
        reload()
        SyncController.shared.publishSoon()
    }

    private func setResolved(id: Int64, resolved: Bool) {
        guard let store else { return }
        try? store.setFeedbackResolved(id: id, resolved: resolved)
        Haptics.switched()
        reload()
        // Peers should see "done" too, or the note comes back open from the other device.
        SyncController.shared.publishSoon()
    }

    private func reload() {
        notes = (try? store?.listFeedback()) ?? []
        attachments = (try? store?.attachmentsByFeedbackUID()) ?? [:]
        model.refreshFeedbackCount()
    }
}

/// A picked or attached image, full screen, because a thumbnail is too small to read a screenshot in.
private struct FullSizeImage: View {
    let image: UIImage
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image).resizable().scaledToFit()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onClose)
                }
            }
        }
    }
}

/// `sheet(item:)` needs Identifiable and UIImage isn't; a wrapper is cheaper than a retroactive
/// conformance on a UIKit type that other code might also want to extend.
private struct ViewedImage: Identifiable {
    let image: UIImage
    var id: Int { image.hash }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
