import SwiftUI
import TimesliceCore

/// The week as seven containers that fill up: how much of each day is spoken for, not when.
///
/// The clock axis went away deliberately. Drawing tracked time at the hour it happened answers "when did
/// I do it" — a question the Metrics day timeline already answers better — and on a planning page it
/// produced 150 fragments a week competing for space with the thing the page is for. A planner needs
/// magnitude only: this much is gone, this much is owed, this much is left.
///
/// Each column is a waking day tall, filled from the bottom:
///
/// - **hatched** — reserved, the non-negotiables, gone before anything competes;
/// - **solid** — hours tracked against an allocation, one blob per allocation per day;
/// - **grey** — tracked against nothing you allocated, which is usually where a plan went;
/// - **dashed** — still owed, and the only part you can still decide about;
/// - **empty** — genuinely free.
///
/// A day that fills to the top has nothing spare, and a day whose blobs would pass the top gets a red cap
/// carrying the excess — so an impossible day looks impossible instead of being described as one.
public struct PlannerWeekGrid: View {
    public enum Kind: Sendable {
        case reserved, tracked, unallocated, owed
    }

    public struct Blob: Identifiable, Sendable {
        /// Allocation id, or a negative sentinel for reserved and unallocated time. NOT the identity —
        /// see `id`.
        public let targetID: Int64
        public let name: String
        public let hours: Double
        public let colorHex: String
        public let kind: Kind

        /// Unique per blob, because one allocation can appear TWICE in a day: an hour tracked against it
        /// and an hour still owed to it. Keyed on the allocation alone, `ForEach` saw duplicate ids and
        /// drew a day's stack twice over — the vllm and office blobs each appeared two times.
        public var id: String { "\(targetID)-\(kind)" }

        public init(targetID: Int64, name: String, hours: Double, colorHex: String, kind: Kind) {
            self.targetID = targetID
            self.name = name
            self.hours = hours
            self.colorHex = colorHex
            self.kind = kind
        }
    }

    public struct DayInput: Identifiable, Sendable {
        public let weekday: Int
        public let label: String
        public let dayOfMonth: Int
        public let isPast: Bool
        public let isToday: Bool
        /// In stacking order, bottom first: reserved, then tracked, then owed.
        public let blobs: [Blob]
        public var id: Int { weekday }

        public init(weekday: Int, label: String, dayOfMonth: Int, isPast: Bool, isToday: Bool,
                    blobs: [Blob]) {
            self.weekday = weekday
            self.label = label
            self.dayOfMonth = dayOfMonth
            self.isPast = isPast
            self.isToday = isToday
            self.blobs = blobs
        }
    }

    public let days: [DayInput]
    /// A waking day: the height of every column, so columns are comparable.
    public let capacityHours: Double
    /// Waking hours already gone today. Nil when the week being viewed isn't the current one.
    public let elapsedHoursToday: Double?
    public let highlight: Int64?
    public var onPick: (Int64) -> Void

    public init(days: [DayInput], capacityHours: Double, elapsedHoursToday: Double?,
                highlight: Int64?, onPick: @escaping (Int64) -> Void = { _ in }) {
        self.days = days
        self.capacityHours = capacityHours
        self.elapsedHoursToday = elapsedHoursToday
        self.highlight = highlight
        self.onPick = onPick
    }

    private static let axisWidth: CGFloat = 30
    private static let gridHeight: CGFloat = 430

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            axis
            GeometryReader { geo in
                let columnWidth = geo.size.width / 7
                HStack(spacing: 0) {
                    ForEach(days) { day in
                        column(day, compact: columnWidth < 96)
                            .frame(width: columnWidth)
                    }
                }
            }
        }
        .frame(height: Self.gridHeight + 24)
    }

    // MARK: - Axis

    private var axis: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 24)          // aligns with the day headers
            ZStack(alignment: .bottomLeading) {
                Color.clear
                ForEach(marks, id: \.self) { hour in
                    Text("\(Int(hour))h")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .offset(y: -height(hour) + 4)
                }
            }
            .frame(height: Self.gridHeight)
        }
        .frame(width: Self.axisWidth, alignment: .leading)
    }

    /// Every four hours, plus the top of the day so the ceiling is labelled.
    private var marks: [Double] {
        var out = Array(stride(from: 0.0, to: capacityHours, by: 4))
        out.append(capacityHours)
        return out
    }

    private func height(_ hours: Double) -> CGFloat {
        guard capacityHours > 0 else { return 0 }
        return Self.gridHeight * CGFloat(min(hours, capacityHours) / capacityHours)
    }

    // MARK: - One day

    private func column(_ day: DayInput, compact: Bool) -> some View {
        let total = day.blobs.reduce(0) { $0 + $1.hours }
        let overflow = max(0, total - capacityHours)
        return VStack(spacing: 0) {
            header(day)
            ZStack(alignment: .bottom) {
                // The container: one waking day, outlined, so "how full is this" has a visible ceiling.
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(day.isToday ? 0.06 : 0.035))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(day.isToday ? Color.accentColor.opacity(0.45)
                                          : Color.primary.opacity(0.08), lineWidth: 1)
                    }

                // What the empty part of the column MEANS, which differs by day: hours nobody has
                // claimed yet on a day still coming, versus hours that went by untracked on one that
                // has gone. Same emptiness, opposite implications, and it was unlabelled either way.
                if capacityHours - total > 1.2 {
                    Text("\(Self.short(capacityHours - total)) \(day.isPast ? "untracked" : "free")")
                        .font(.system(size: compact ? 8 : 9))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .offset(y: -height(total) - 12)
                }

                VStack(spacing: 1) {
                    // A VStack given more height than its content CENTRES it, so every day's stack was
                    // floating in the middle of its container instead of resting on the floor — which is
                    // the one thing a "fills up" reading depends on.
                    Spacer(minLength: 0)
                    if overflow > 0.02 { overflowCap(overflow, compact: compact) }
                    // Reversed: blobs are ordered bottom-to-top and a VStack lays out top-to-bottom.
                    ForEach(day.blobs.reversed()) { blob in
                        blobView(blob, compact: compact, scale: scale(day, total: total))
                    }
                }
                .padding(3)
                .frame(height: Self.gridHeight)
                .clipped()

                // How much of today has gone. This is the whole of the clock the page needs: late in the
                // day the rule sits near the top, and dashed blobs above it are visibly not happening.
                if day.isToday, let elapsed = elapsedHoursToday, elapsed > 0 {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.accentColor).frame(height: 1)
                        Circle().fill(Color.accentColor).frame(width: 5, height: 5).offset(x: -2)
                    }
                    .offset(y: -height(elapsed))
                    .help("\(Self.short(elapsed)) of today has gone")
                }
            }
            .frame(height: Self.gridHeight)
            .opacity(day.isPast ? 0.85 : 1)
            .help(tooltip(day, total: total))
        }
        .padding(.horizontal, 2)
    }

    /// How much to squeeze an over-full day so its blobs stay inside the container.
    ///
    /// Accounts for the spacing between blobs and the overflow cap, not just the hours: leaving those out
    /// let a full day's stack grow past the top of its own outline and over the day heading above it,
    /// which read as a layout fault rather than as a full day. The excess is still stated by the cap.
    private func scale(_ day: DayInput, total: Double) -> Double {
        let drawable = day.blobs.filter { $0.hours > 0.02 }.count
        let chrome = CGFloat(max(0, drawable - 1)) + 4 + (total > capacityHours ? 14 : 0)
        let available = max(20, Self.gridHeight - chrome)
        let wanted = height(min(total, capacityHours)) * CGFloat(max(1, total / capacityHours))
        guard wanted > available else { return min(1, Double(available / max(1, wanted))) }
        return Double(available / wanted)
    }

    private func header(_ day: DayInput) -> some View {
        HStack(spacing: 4) {
            Text(day.label).font(.system(size: 11, weight: day.isToday ? .semibold : .regular))
            Text("\(day.dayOfMonth)")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(day.isToday ? Color.white : Color.secondary.opacity(0.7))
                .padding(.horizontal, day.isToday ? 5 : 0)
                .padding(.vertical, day.isToday ? 1 : 0)
                .background { if day.isToday { Capsule().fill(Color.accentColor) } }
        }
        .foregroundStyle(day.isToday ? Color.primary
                         : (day.isPast ? Color.secondary.opacity(0.55) : .secondary))
        .frame(height: 24)
    }

    /// One allocation's share of one day.
    ///
    /// `scale` squeezes an over-full day so its blobs still fit inside the container. The excess is not
    /// hidden by that — it's stated by the red cap — but a column whose contents spilled past its own
    /// outline looked like a layout fault rather than a full day.
    @ViewBuilder
    private func blobView(_ blob: Blob, compact: Bool, scale: Double) -> some View {
        let tint = Color(hex: blob.colorHex)
        let dim = highlight != nil && highlight != blob.targetID
        let h = height(blob.hours) * CGFloat(scale)
        ZStack(alignment: .topLeading) {
            switch blob.kind {
            case .reserved:
                Hatch(color: .secondary).clipShape(RoundedRectangle(cornerRadius: 3))
            case .tracked:
                RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.9))
            case .unallocated:
                // Tracked, but against nothing you allocated. Distinct from both a solid allocation blob
                // and from empty space, because it is neither — it's usually where the plan went.
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.30))
                    .overlay {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                    }
            case .owed:
                // Dashed, with the colour on the edge rather than in the fill: a low-alpha tint of a
                // dark hue vanished against the column and left a label floating over nothing.
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06))
                    .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 3) }
                    .overlay {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(tint.opacity(0.6),
                                          style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            if h > 9 {
                VStack(alignment: .leading, spacing: 0) {
                    Text(blob.name)
                        .font(.system(size: compact ? 8 : 9,
                                      weight: blob.kind == .tracked ? .medium : .regular))
                        .lineLimit(1).truncationMode(.tail)
                    if h > 26 {
                        Text(Self.short(blob.hours))
                            .font(.system(size: compact ? 8 : 9, design: .monospaced))
                            .opacity(0.7)
                    }
                }
                .foregroundStyle(blob.kind == .tracked ? Color.white.opacity(0.95) : .secondary)
                .padding(.horizontal, blob.kind == .owed ? 6 : 4)
                .padding(.top, 1)
            }
        }
        .frame(height: max(3, h))
        .opacity(dim ? 0.15 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if blob.targetID >= 0 { onPick(blob.targetID) } }
        .help("\(blob.name) · \(Self.short(blob.hours))"
              + (blob.kind == .owed ? " still to fit" : ""))
    }

    /// What won't fit in the day at all, capping the column.
    private func overflowCap(_ hours: Double, compact: Bool) -> some View {
        Text(compact ? "+\(Self.short(hours))" : "+\(Self.short(hours)) over")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 13)
            .background(RoundedRectangle(cornerRadius: 3).fill(PlannerPalette.over))
            .help("\(Self.short(hours)) more than this day holds.")
    }

    private func tooltip(_ day: DayInput, total: Double) -> String {
        var lines = ["\(day.label) \(day.dayOfMonth) — \(Self.short(total)) of "
                     + "\(Self.short(capacityHours)) spoken for"]
        for blob in day.blobs.reversed() where blob.hours > 0.02 {
            lines.append("  \(blob.name)  \(Self.short(blob.hours))"
                         + (blob.kind == .owed ? "  (still to fit)" : ""))
        }
        let free = capacityHours - total
        lines.append(free > 0.02 ? "\(Self.short(free)) free" : "nothing free")
        return lines.joined(separator: "\n")
    }

    public static func short(_ hours: Double) -> String {
        if hours >= 10 { return "\(Int(hours.rounded()))h" }
        if hours >= 1 {
            return hours == hours.rounded() ? "\(Int(hours))h" : String(format: "%.1fh", hours)
        }
        return "\(Int((hours * 60).rounded()))m"
    }
}

/// Diagonal hatching. Used for reserved time, which is neither something you did nor something you can
/// still choose to do, so it should look like neither.
public struct Hatch: View {
    let color: Color

    public init(color: Color) { self.color = color }

    public var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                var path = Path()
                let step: CGFloat = 5
                var x = -size.height
                while x < size.width + size.height {
                    path.move(to: CGPoint(x: x, y: size.height))
                    path.addLine(to: CGPoint(x: x + size.height, y: 0))
                    x += step
                }
                context.stroke(path, with: .color(color.opacity(0.30)), lineWidth: 1)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(color.opacity(0.06))
    }
}

/// Colours the planner owns. `over` is the same red the metrics selection overlay uses, so one colour
/// means one thing across the app.
public enum PlannerPalette {
    public static let over = Color(red: 0.90, green: 0.30, blue: 0.32)
}
