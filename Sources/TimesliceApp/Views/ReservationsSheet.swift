import SwiftUI
import TimesliceCore

/// The hours that are gone before any allocation gets a look in.
///
/// These have to be declared, and that isn't a preference — it's forced by what the database can see.
/// Tracked time averages about five hours of a sixteen-hour waking day, so the rest (meals, commute,
/// getting ready, anything that never becomes a task) leaves no trace at all. A planner that inferred
/// free time from history would believe a Tuesday has ten hours spare when its allocations already
/// ask for fourteen.
///
/// Deliberately coarse: hours per weekday, not times of day. The app has no notion of when an event
/// starts and shouldn't grow one — "three hours of Tuesday are gone" is enough to decide whether the
/// week fits, and it's a thing you can state without keeping a calendar in step.
struct ReservationsSheet: View {
    let store: IntervalStore
    var onClose: () -> Void

    @State private var rows: [Reservation] = []
    @State private var draftName = ""
    @State private var draftHours = ""
    @State private var draftDays: Weekdays = .all
    /// Row being renamed, and the text. Double-click to enter, like task and note rows.
    @State private var editingID: Int64?
    @State private var editName = ""
    @FocusState private var editFocused: Bool

    private static let dayNames = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Non-negotiables").font(.headline)
                Text(totalText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            Text("Hours already spoken for, per weekday. The planner takes these first, so what's "
                 + "left is what your allocations actually compete for.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.top, 10)

            addRow
                .padding(.horizontal, 16).padding(.vertical, 10)

            Divider()

            if rows.isEmpty {
                Text("Nothing reserved yet")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(rows) { row(for: $0) }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 560, height: 460)
        .onAppear(perform: reload)
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            TextField("What (commute, meals, standup…)", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
                .onSubmit(add)
            // Same filtering as the allocation hours field, so "1.5" works and "abc" can't be typed.
            TextField("hours", text: Binding(
                get: { draftHours },
                set: { draftHours = NumericInput.hours($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 60)
            .onSubmit(add)
            Text("per day on").font(.caption).foregroundStyle(.secondary)
            weekdayBubbles(draftDays) { draftDays = $0 }
            Spacer()
            Button("Add", action: add)
                .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty
                          || (Double(draftHours) ?? 0) <= 0)
        }
    }

    private func row(for reservation: Reservation) -> some View {
        HStack(spacing: 8) {
            if editingID == reservation.id {
                TextField("", text: $editName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .focused($editFocused)
                    .onSubmit { commitRename(reservation) }
                    // A TextField swallows onExitCommand, so Esc needs catching explicitly.
                    .onKeyPress(.escape) { editingID = nil; return .handled }
                    .onChange(of: editFocused) { _, focused in
                        if !focused, editingID == reservation.id { commitRename(reservation) }
                    }
            } else {
                Text(reservation.name)
                    .font(.callout).lineLimit(1).truncationMode(.tail)
                    .frame(width: 150, alignment: .leading)
                    .help(reservation.name)
                    .onTapGesture(count: 2) {
                        editName = reservation.name
                        editingID = reservation.id
                        editFocused = true
                    }
            }

            // ± in half-hour steps, plus a typeable field: reaching 11h in half-hour clicks is 22
            // presses, and the allocation editor already learned that lesson.
            Button("−") { adjust(reservation, by: -1800) }.buttonStyle(.borderless)
            HoursField(seconds: reservation.secondsPerDay) { secs in
                try? store.updateReservation(id: reservation.id, secondsPerDay: secs)
                reload()
            }
            Button("+") { adjust(reservation, by: 1800) }.buttonStyle(.borderless)
            Text("/day").font(.system(size: 10)).foregroundStyle(.tertiary)

            weekdayBubbles(reservation.weekdays) { days in
                try? store.updateReservation(id: reservation.id, weekdays: days)
                reload()
            }

            Spacer(minLength: 4)

            Text(weekText(reservation))
                .font(.system(size: 10, design: .monospaced)).monospacedDigit()
                .foregroundStyle(.secondary)

            Button {
                try? store.deleteReservation(id: reservation.id)
                reload()
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Remove this reservation")
        }
    }

    /// The same bubbles the allocation editor uses, so the two read as one vocabulary.
    private func weekdayBubbles(_ current: Weekdays,
                                _ set: @escaping (Weekdays) -> Void) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<7, id: \.self) { bit in
                let on = current.effective.contains(weekday: bit + 1)
                Button {
                    let next = current.effective.toggling(weekday: bit + 1)
                    // Turning the last one off would mean a reservation on no days, which is just a
                    // deletion written confusingly. Empty means every day, as it does for allocations.
                    set(next.selectedCount == 0 ? .all : next)
                } label: {
                    Text(Self.dayNames[bit])
                        .font(.system(size: 9, weight: on ? .semibold : .regular))
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(on ? Color.accentColor.opacity(0.28)
                                                     : Color.secondary.opacity(0.10)))
                        .foregroundStyle(on ? Color.accentColor : Color.secondary)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Actions

    private func add() {
        let hours = Double(draftHours) ?? 0
        guard !draftName.trimmingCharacters(in: .whitespaces).isEmpty, hours > 0 else { return }
        _ = try? store.addReservation(name: draftName, weekdays: draftDays,
                                     secondsPerDay: hours * 3600)
        draftName = ""
        draftHours = ""
        draftDays = .all
        reload()
    }

    private func adjust(_ reservation: Reservation, by delta: TimeInterval) {
        let next = max(1800, reservation.secondsPerDay + delta)
        try? store.updateReservation(id: reservation.id, secondsPerDay: next)
        reload()
    }

    private func commitRename(_ reservation: Reservation) {
        // An empty name is treated as no change rather than as a delete — the ✕ is for that.
        try? store.updateReservation(id: reservation.id, name: editName)
        editingID = nil
        reload()
    }

    private func reload() {
        rows = (try? store.listReservations()) ?? []
    }

    private func weekText(_ r: Reservation) -> String {
        let weekly = r.secondsPerDay * Double(r.weekdays.effective.selectedCount)
        return "\(hoursText(weekly))/wk"
    }

    private var totalText: String {
        let weekly = rows.reduce(0.0) { $0 + $1.secondsPerDay
                                         * Double($1.weekdays.effective.selectedCount) }
        return rows.isEmpty ? "" : "\(hoursText(weekly)) a week reserved"
    }

    private func hoursText(_ seconds: TimeInterval) -> String {
        let h = seconds / 3600
        if h >= 1 { return h == h.rounded() ? "\(Int(h))h" : String(format: "%.1fh", h) }
        return "\(Int((seconds / 60).rounded()))m"
    }
}
