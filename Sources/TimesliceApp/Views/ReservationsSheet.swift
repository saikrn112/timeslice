import SwiftUI
import TimesliceCore

/// How many hours each weekday actually has available for allocations.
///
/// This started as "reservations" — named blocks of non-negotiable time, subtracted from a waking day.
/// The naming was the problem: a single flat block of unavailable time is just a smaller waking day, and
/// `wakingHours` already expresses that. The only thing it could say that the setting couldn't is that
/// **weekdays differ** — a commute on Monday that doesn't exist on Sunday.
///
/// So it's stated the way it's used: seven days, each with the hours available to plan with, defaulting to
/// the waking day. Underneath, a day set below the default is stored as one `Reservation` for the
/// difference, which keeps the sync and the solver untouched.
///
/// Still deliberately coarse: hours per weekday, no times of day. "Tuesday has 11 hours in it" is enough
/// to decide whether a week fits, and it's a thing you can state without keeping a calendar in step.
struct ReservationsSheet: View {
    let store: IntervalStore
    /// The waking day, and the default for every weekday.
    let wakingHours: Double
    var onClose: () -> Void

    @State private var rows: [Reservation] = []

    private static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday",
                                  "Friday", "Saturday"]
    /// The name given to the stored difference. Not shown anywhere.
    private static let marker = "unavailable"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Available hours").font(.headline)
                Text(totalText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            Text("Hours each day actually has for your allocations. A waking day is "
                 + "\(hoursText(wakingHours * 3600)) — lower a day that has less, because meals, "
                 + "commute and getting ready never become tasks and the planner would otherwise "
                 + "believe you have hours you don't.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 12)

            Divider()

            VStack(spacing: 6) {
                ForEach(1...7, id: \.self) { weekday in
                    row(weekday)
                }
            }
            .padding(16)

            Spacer(minLength: 0)

            HStack {
                Button("Reset all to \(hoursText(wakingHours * 3600))") { resetAll() }
                    .buttonStyle(.link).font(.system(size: 11))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.bottom, 14)
        }
        .frame(width: 460, height: 460)
        .onAppear(perform: reload)
    }

    private func row(_ weekday: Int) -> some View {
        let available = availableHours(weekday)
        let isDefault = abs(available - wakingHours) < 0.01
        return HStack(spacing: 10) {
            Text(Self.dayNames[weekday - 1])
                .font(.callout)
                .frame(width: 92, alignment: .leading)

            Button("−") { adjust(weekday, by: -0.5) }.buttonStyle(.borderless)
                .disabled(available <= 0.5)
            HoursField(seconds: available * 3600) { seconds in
                set(weekday, hours: seconds / 3600)
            }
            Button("+") { adjust(weekday, by: 0.5) }.buttonStyle(.borderless)
                .disabled(available >= wakingHours - 0.01)

            // How much of the day this leaves out, so the trade-off is visible while you type.
            Text(isDefault ? "full day"
                 : "\(hoursText((wakingHours - available) * 3600)) unavailable")
                .font(.system(size: 10))
                .foregroundStyle(isDefault ? .tertiary : .secondary)
                .frame(width: 120, alignment: .leading)

            // The bar is the day: filled is what you can plan with.
            GeometryReader { geo in
                let fraction = wakingHours > 0 ? min(1, available / wakingHours) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.16))
                    Capsule().fill(Color.accentColor.opacity(0.75))
                        .frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(height: 8)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Reading and writing

    /// Available hours for a weekday: the waking day minus everything stored against it.
    ///
    /// Sums every reservation claiming the day, not just this sheet's own marker, so hours declared by an
    /// older build (or by the phone) still count instead of silently disappearing.
    private func availableHours(_ weekday: Int) -> Double {
        let taken = rows
            .filter { $0.weekdays.effective.contains(weekday: weekday) }
            .reduce(0.0) { $0 + $1.secondsPerDay } / 3600
        return max(0, min(wakingHours, wakingHours - taken))
    }

    private func adjust(_ weekday: Int, by delta: Double) {
        set(weekday, hours: availableHours(weekday) + delta)
    }

    private func set(_ weekday: Int, hours: Double) {
        let clamped = max(0, min(wakingHours, hours))
        let unavailable = wakingHours - clamped
        let mask = Weekdays(rawValue: 1 << (weekday - 1))

        // Clear anything already claiming this day, then store one row for the difference. Rewriting
        // rather than adjusting keeps a day from accumulating several overlapping claims, which is how
        // "available" would stop matching what the solver subtracts.
        for existing in rows where existing.weekdays.effective.contains(weekday: weekday) {
            if existing.weekdays.effective.selectedCount == 1 {
                try? store.deleteReservation(id: existing.id)
            } else {
                // A multi-day row from an older build: narrow it rather than deleting other days' hours.
                let narrowed = existing.weekdays.effective.toggling(weekday: weekday)
                try? store.updateReservation(id: existing.id, weekdays: narrowed)
            }
        }
        if unavailable > 0.01 {
            _ = try? store.addReservation(name: Self.marker, weekdays: mask,
                                          secondsPerDay: unavailable * 3600)
        }
        reload()
    }

    private func resetAll() {
        for existing in rows { try? store.deleteReservation(id: existing.id) }
        reload()
    }

    private func reload() {
        rows = (try? store.listReservations()) ?? []
    }

    private var totalText: String {
        let weekly = (1...7).reduce(0.0) { $0 + availableHours($1) }
        return "\(hoursText(weekly * 3600)) a week to plan with"
    }

    private func hoursText(_ seconds: TimeInterval) -> String {
        let h = seconds / 3600
        if h >= 1 { return h == h.rounded() ? "\(Int(h))h" : String(format: "%.1fh", h) }
        return "\(Int((seconds / 60).rounded()))m"
    }
}
