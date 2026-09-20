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
        /// Days of a neighbouring month. A month view's columns are whole calendar weeks, so the first and
        /// last of them reach outside; those hours are drawn cross-hatched at the TOP of the column, above
        /// everything the month counts, because the column fills from the floor with its own hours.
        case otherMonth
        /// Hours that went by with nothing recorded. On a past day it's the rest of the day; on today it's
        /// the elapsed part that wasn't tracked. Either way it is gone, and drawing it is what makes a
        /// column add up to a whole day instead of trailing off into ambiguous empty space.
        case untracked
    }

    public struct Blob: Identifiable, Sendable {
        /// Allocation id, or a negative sentinel for reserved and unallocated time. NOT the identity —
        /// see `id`.
        public let targetID: Int64
        public let name: String
        public let hours: Double
        public let colorHex: String
        public let kind: Kind
        /// What made this blob up, largest first — "kvcache 1.2h". Shown in its tooltip.
        ///
        /// The reason it exists: hovering the grey "unallocated" block asked the obvious question, and
        /// "unallocated 2.4h" answered none of it. The blob knows its own hours; only the caller knows
        /// which tasks they came from.
        public let detail: [String]

        /// Unique per blob, because one allocation can appear TWICE in a day: an hour tracked against it
        /// and an hour still owed to it. Keyed on the allocation alone, `ForEach` saw duplicate ids and
        /// drew a day's stack twice over — the vllm and office blobs each appeared two times.
        public var id: String { "\(targetID)-\(kind)" }

        public init(targetID: Int64, name: String, hours: Double, colorHex: String, kind: Kind,
                    detail: [String] = []) {
            self.targetID = targetID
            self.name = name
            self.hours = hours
            self.colorHex = colorHex
            self.kind = kind
            self.detail = detail
        }
    }

    public struct DayInput: Identifiable, Sendable {
        public let weekday: Int
        public let label: String
        /// The chip beside the label. Nil for a column that isn't one day — a week of a month names its
        /// range in `label` instead, and a single number there would be a lie about which day it is.
        public let dayOfMonth: Int?
        /// This column's own ceiling, when it differs from the grid's.
        public let capacityHours: Double?
        /// How much of that ceiling belongs to the window being viewed. A month's columns are whole calendar
        /// weeks, so the first and last reach into a neighbouring month; "free" has to measure against the
        /// part this month owns, or a week with six days in another month reads as nearly empty.
        public let countedHours: Double?
        /// Drawn pinned to the TOP of the column, above everything it counts: the days of a neighbouring
        /// month. Pinned rather than stacked, because the gap beneath it is this month's free hours and a
        /// stacked cap would sit straight on top of the work instead of at the ceiling.
        public let cap: Blob?
        public let isPast: Bool
        public let isToday: Bool
        /// In stacking order, bottom first: reserved, then tracked, then owed.
        public let blobs: [Blob]
        /// Hours this day can't hold, drawn hanging BELOW the floor. Same hour scale as the column above,
        /// so a 1.7h overflow is exactly as tall as 1.7h inside the day — the point being that you can see
        /// how much of the day it would have taken.
        public let leftovers: [Blob]
        public var id: Int { weekday }

        public init(weekday: Int, label: String, dayOfMonth: Int?, isPast: Bool, isToday: Bool,
                    blobs: [Blob], leftovers: [Blob] = [], capacityHours: Double? = nil,
                    countedHours: Double? = nil, cap: Blob? = nil) {
            self.capacityHours = capacityHours
            self.countedHours = countedHours
            self.cap = cap
            self.leftovers = leftovers
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
    /// What to call the pool beneath the week. A live week's is hours with nowhere left to put them; a
    /// finished week's is hours that never happened, and the same words don't fit both.
    public var leftoverCaption: String = "no room for these"
    public var onPick: (Int64) -> Void
    /// Double-click: "show me this, properly". Carries the blob's allocation (negative for unallocated)
    /// and the weekday, which is everything the Metrics page needs to answer for that day.
    public var onOpen: (Int64, Int) -> Void

    public init(days: [DayInput], capacityHours: Double, elapsedHoursToday: Double?,
                highlight: Int64?, leftoverCaption: String = "no room for these",
                onPick: @escaping (Int64) -> Void = { _ in },
                onOpen: @escaping (Int64, Int) -> Void = { _, _ in }) {
        self.days = days
        self.capacityHours = capacityHours
        self.elapsedHoursToday = elapsedHoursToday
        self.highlight = highlight
        self.leftoverCaption = leftoverCaption
        self.onPick = onPick
        self.onOpen = onOpen
    }

    private static let axisWidth: CGFloat = 30
    /// Taller than it needs to be for the axis alone: every block has a minimum height so it can carry a
    /// label, and the shorter the grid the more that floor distorts the proportions between blocks. Extra
    /// height is the cheapest way to make the sizes honest.
    private static let gridHeight: CGFloat = 500
    /// Space between the week and the pool beneath it. Generous on purpose: they are two different
    /// statements — what the week holds, and what it doesn't — and a few points of padding would read as
    /// one continuous column.
    private static let basementGap: CGFloat = 26

    public var body: some View {
        ZStack(alignment: .topLeading) {
            // The dividing rule, drawn across everything so the pool reads as a separate panel rather than
            // seven columns that happen to continue.
            if basementHeight > 0 {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: Self.gridHeight + 24 + Self.basementGap / 2 - 12)
                    Text(leftoverCaption)
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                    Rectangle().fill(Color.primary.opacity(0.18)).frame(height: 1)
                        .padding(.top, 3)
                    Spacer(minLength: 0)
                }
            }
            columnsAndAxis
        }
        .frame(height: Self.gridHeight + 24
                       + (basementHeight > 0 ? basementHeight + Self.basementGap : 0))
    }

    private var columnsAndAxis: some View {
        HStack(alignment: .top, spacing: 0) {
            axis
            GeometryReader { geo in
                let columnWidth = geo.size.width / CGFloat(max(1, days.count))
                HStack(spacing: 0) {
                    ForEach(days) { day in
                        column(day, compact: columnWidth < 96)
                            .frame(width: columnWidth)
                    }
                }
            }
        }
    }

    /// How tall the basement needs to be: the worst day's overflow, on the same scale, capped so one wild
    /// day can't push the grid off the screen.
    private var basementHeight: CGFloat {
        let worst = days.map { $0.leftovers.reduce(0) { $0 + $1.hours } }.max() ?? 0
        guard worst > 0.02 else { return 0 }
        // A floor of 78pt: the blocks in here are usually small, and scaling them faithfully made a 30m
        // leftover a hairline in a slot too short to read. The pool's job is to be readable, not to be
        // proportional to the emptiest possible week.
        return min(190, max(78, height(worst) + 12))
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
            if basementHeight > 0 {
                // No hour marks down here: the blocks say how long they are, and a second axis would imply
                // negative time. The caption lives above the pool instead of in this 30pt gutter, where it
                // wrapped to "leftove / r".
                Color.clear.frame(height: Self.basementGap + basementHeight)
            }
        }
        .frame(width: Self.axisWidth, alignment: .leading)
    }

    /// Every four hours for a day, plus the ceiling so the top is labelled.
    ///
    /// The step grows with the scale: a month's week columns are seven waking days tall, and a mark every
    /// four hours there is twenty-one labels stacked into 500 points.
    private var marks: [Double] {
        let step: Double = capacityHours > 30 ? 12 : 4
        var out = Array(stride(from: 0.0, to: capacityHours - step / 2, by: step))
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
        // A column can be shorter than the grid: a month's first week may hold five days where the others
        // hold seven. Drawn floor-aligned inside the full height, so every column shares a baseline — which
        // is the whole basis of comparing how full they are.
        let cap = day.capacityHours ?? capacityHours
        let counted = day.countedHours ?? cap
        let box = height(cap)
        return VStack(spacing: 0) {
            header(day)
            Spacer(minLength: 0)
            ZStack(alignment: .bottom) {
                // The container: one waking day, outlined, so "how full is this" has a visible ceiling.
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(day.isToday ? 0.06 : 0.035))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(day.isToday ? Color.accentColor.opacity(0.45)
                                          : Color.primary.opacity(0.08), lineWidth: 1)
                    }
                    .help(tooltip(day, total: total))

                // The empty top is hours you still have — on a past day there are none, because the
                // untracked band accounts for them.
                // Pinned to the top of the column rather than floating just above the stack, where it
                // collided with whatever block happened to reach it — "stonks 1h" and "4h free" printed over
                // each other.
                // Days of a neighbouring month, at the ceiling. Everything this month counts is below it.
                if let outside = day.cap, outside.hours > 0.02 {
                    VStack(spacing: 0) {
                        blobView(outside, compact: compact, scale: 1, weekday: day.weekday)
                            .frame(height: max(12, height(outside.hours)))
                        Spacer(minLength: 0)
                    }
                    .padding(3)
                    .frame(height: box)
                }

                if counted - total > 1.2 {
                    VStack(spacing: 0) {
                        // Under the cap when there is one, so the two don't print over each other.
                        if let outside = day.cap, outside.hours > 0.02 {
                            Color.clear.frame(height: max(12, height(outside.hours)) + 2)
                        }
                        Text("\(Self.short(counted - total)) \(day.isToday ? "left" : "free")")
                            .font(.system(size: compact ? 8 : 9))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity)
                }

                VStack(spacing: 1) {
                    // A VStack given more height than its content CENTRES it, so every day's stack was
                    // floating in the middle of its container instead of resting on the floor — which is
                    // the one thing a "fills up" reading depends on.
                    Spacer(minLength: 0)
                    // Reversed: blobs are ordered bottom-to-top and a VStack lays out top-to-bottom.
                    ForEach(day.blobs.reversed()) { blob in
                        blobView(blob, compact: compact, scale: scale(day, total: total),
                                 weekday: day.weekday)
                    }
                }
                .padding(3)
                .frame(height: height(counted))
                .clipped()

            }
            .frame(height: box)
            .opacity(day.isPast ? 0.85 : 1)

            if basementHeight > 0 {
                Color.clear.frame(height: Self.basementGap)
                basement(day, compact: compact)
                    .frame(height: basementHeight)
            }
        }
        .padding(.horizontal, 2)
    }

    /// What this day couldn't hold, hanging below the floor.
    ///
    /// Drawn downward from the top of the basement so the blocks touch the line they fell through, and in the
    /// same colours and dashes as the plan above — they are the same blocks, just homeless.
    private func basement(_ day: DayInput, compact: Bool) -> some View {
        let total = day.leftovers.reduce(0.0) { $0 + $1.hours }
        let wanted = day.leftovers.reduce(0.0 as CGFloat) { $0 + max(12, height($1.hours)) }
        let room = basementHeight - 8
        let scale = wanted > room ? Double(room / wanted) : 1
        return VStack(spacing: 1) {
            ForEach(day.leftovers) { blob in
                blobView(blob, compact: compact, scale: scale, weekday: day.weekday)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 3)
        .padding(.top, 3)
        .frame(maxWidth: .infinity)
        // A darker well than the day above it, and no red. These blocks are hours you haven't found room
        // for — not an error, and colouring them like one made a normal week look broken.
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.black.opacity(0.22))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                }
        }
    }

    /// How much to squeeze an over-full day so its blobs stay inside the container.
    ///
    /// Accounts for the spacing between blobs and the overflow cap, not just the hours: leaving those out
    /// let a full day's stack grow past the top of its own outline and over the day heading above it,
    /// which read as a layout fault rather than as a full day. The excess is still stated by the cap.
    private func scale(_ day: DayInput, total: Double) -> Double {
        let drawn = day.blobs.filter { $0.hours > 0.02 }
        let chrome = CGFloat(max(0, drawn.count - 1)) + 4
        let available = max(20, height(day.countedHours ?? day.capacityHours ?? capacityHours) - chrome)
        // What the blobs will actually occupy, minimum heights included — otherwise a day of many small
        // blocks is scaled as if they were hairlines and overflows its own container.
        let wanted = drawn.reduce(0.0 as CGFloat) { $0 + max(12, height($1.hours)) }
        guard wanted > available else { return 1 }
        return Double(available / wanted)
    }

    private func header(_ day: DayInput) -> some View {
        HStack(spacing: 4) {
            Text(day.label).font(.system(size: 11, weight: day.isToday ? .semibold : .regular))
            if let dayOfMonth = day.dayOfMonth {
                Text("\(dayOfMonth)")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(day.isToday ? Color.white : Color.secondary.opacity(0.7))
                    .padding(.horizontal, day.isToday ? 5 : 0)
                    .padding(.vertical, day.isToday ? 1 : 0)
                    .background { if day.isToday { Capsule().fill(Color.accentColor) } }
            }
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
    private func blobView(_ blob: Blob, compact: Bool, scale: Double, weekday: Int) -> some View {
        let tint = Color(hex: blob.colorHex)
        let dim = highlight != nil && highlight != blob.targetID
        let h = height(blob.hours) * CGFloat(scale)
        ZStack(alignment: .topLeading) {
            switch blob.kind {
            case .otherMonth:
                Hatch(color: .secondary, crossed: true).clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color.primary.opacity(0.10),
                                          style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    }
            case .reserved:
                Hatch(color: .secondary).clipShape(RoundedRectangle(cornerRadius: 3))
            case .tracked:
                RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.9))
            case .untracked:
                // Flat, and coloured by nothing: it is the absence of work rather than a kind of it. Its
                // size is the message.
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.055))
                    .overlay(alignment: .top) {
                        Rectangle().fill(Color.primary.opacity(0.16)).frame(height: 1)
                    }
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
            case .untracked:
                // Flat, and coloured by nothing: it is the absence of work rather than a kind of it. Its
                // size is the message.
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.055))
                    .overlay(alignment: .top) {
                        Rectangle().fill(Color.primary.opacity(0.16)).frame(height: 1)
                    }
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

            if true {
                VStack(alignment: .leading, spacing: 0) {
                    Text(blob.name)
                        .font(.system(size: compact ? 8 : 9,
                                      weight: blob.kind == .tracked ? .medium : .regular))
                        .lineLimit(1).truncationMode(.tail)
                    if h > 26 {
                        Text(Self.short(blob.hours))
                            .font(.system(size: compact ? 8 : 9, design: .monospaced))
                            .opacity(0.75)
                    }
                }
                .foregroundStyle(blob.kind == .tracked ? Color.white.opacity(0.95) : .secondary)
                .padding(.horizontal, blob.kind == .owed ? 6 : 4)
                .padding(.top, 1)
            }
        }
        // Never thinner than a label. A three-point bar of colour with no name is unexplainable — "why is
        // vllm at the top of Friday?" was exactly that — so a block that exists at all is drawn big enough
        // to say what it is, and the column's scale absorbs the difference.
        .frame(height: max(12, h))
        .opacity(dim ? 0.15 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpen(blob.targetID, weekday) }
        .onTapGesture { onPick(blob.targetID) }
        .help(blobTooltip(blob))
    }

    private func blobTooltip(_ blob: Blob) -> String {
        var suffix = ""
        switch blob.kind {
        case .owed: suffix = " still wanted today"
        case .untracked: suffix = " with nothing tracked"
        default: break
        }
        var lines = ["\(blob.name) · \(Self.short(blob.hours))" + suffix]
        lines += blob.detail
        if blob.kind == .tracked || blob.kind == .unallocated {
            lines.append("double-click to see this day in Metrics")
        }
        return lines.joined(separator: "\n")
    }

    private func tooltip(_ day: DayInput, total: Double) -> String {
        let cap = day.countedHours ?? day.capacityHours ?? capacityHours
        let heading = day.dayOfMonth.map { "\(day.label) \($0)" } ?? day.label
        var lines = ["\(heading) — \(Self.short(total)) of \(Self.short(cap)) spoken for"]
        if let outside = day.cap, outside.hours > 0.02 {
            lines.append("\(outside.name) — not counted here")
        }
        for blob in day.blobs.reversed() where blob.hours > 0.02 {
            lines.append("  \(blob.name)  \(Self.short(blob.hours))"
                         + (blob.kind == .owed ? "  (still to fit)" : ""))
        }
        let free = cap - total
        if free > 0.02 {
            lines.append("\(Self.short(free)) free")
        } else if -free > 0.02 {
            // Tracked more than the column holds. Not an overflowing plan — an overflowing day.
            lines.append("\(Self.short(-free)) past \(Self.short(cap))")
        } else {
            lines.append("nothing free")
        }
        // The rule, once per day rather than on every block: these add up to the day because each hour is
        // drawn under one allocation only. An allocation's own progress counts shared hours too, which is
        // why its bar in the list can read higher than its blocks here.
        lines.append("")
        lines.append("Each hour appears once, under the narrowest allocation covering it.")
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
    /// Lines both ways. Used for hours that belong to a neighbouring month: they have to read as "not part of
    /// this column's arithmetic", and a single-direction hatch already means reserved time.
    let crossed: Bool

    public init(color: Color, crossed: Bool = false) {
        self.color = color
        self.crossed = crossed
    }

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
                if crossed {
                    var back = -size.height
                    while back < size.width + size.height {
                        path.move(to: CGPoint(x: back, y: 0))
                        path.addLine(to: CGPoint(x: back + size.height, y: size.height))
                        back += step
                    }
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
