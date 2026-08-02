import SwiftUI
import TimesliceCore

/// The global metrics filter: granularity pills + a ‹ › stepper + "Today". Everything below the
/// bar reads the resolved range, so no two charts can disagree.
struct RangeFilterBar: View {
    @Binding var range: DateRange
    let earliest: Date?

    var body: some View {
        HStack(spacing: 10) {
            pills
            Spacer(minLength: 8)
            stepper
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var pills: some View {
        HStack(spacing: 4) {
            ForEach(RangeUnit.allCases, id: \.rawValue) { unit in
                let selected = range.unit == unit
                Button {
                    // If you're looking at the *current* period, switching units keeps you current
                    // ("this week" → "this month"). Only a deliberately-historical view carries its
                    // anchor over — otherwise stepping back once would strand every later switch
                    // in the past and force a trip through "Today".
                    let anchor = range.isCurrent() ? Date() : min(range.start, Date())
                    range = DateRange.resolve(unit: unit, anchor: anchor, earliest: earliest)
                } label: {
                    Text(unit.rawValue)
                        .font(.system(size: 11, weight: selected ? .bold : .medium, design: .rounded))
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                        .frame(minWidth: 26)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(selected ? Color.accentColor : Color.secondary.opacity(0.14))
                        )
                }
                .buttonStyle(.plain)
                .help(helpText(unit))
            }
        }
    }

    private var stepper: some View {
        HStack(spacing: 8) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .disabled(range.unit == .all)

            Text(range.label())
                .font(.system(.subheadline, design: .rounded)).fontWeight(.medium)
                .frame(minWidth: 150)
                .multilineTextAlignment(.center)

            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .disabled(range.unit == .all || atPresentEdge)

            Button("Today") {
                range = DateRange.resolve(unit: range.unit, anchor: Date(), earliest: earliest)
            }
            .buttonStyle(.link)
            .disabled(range.isCurrent())
        }
    }

    /// True when stepping forward would move past now.
    private var atPresentEdge: Bool {
        range.stepped(by: 1, earliest: earliest).start > Date()
    }

    private func step(_ delta: Int) {
        let next = range.stepped(by: delta, earliest: earliest)
        guard next.start <= Date() else { return }   // never browse the future
        range = next
    }

    private func helpText(_ unit: RangeUnit) -> String {
        switch unit {
        case .day: return "One day"
        case .week: return "One week"
        case .month: return "One month"
        case .sixMonths: return "Six months"
        case .year: return "One year"
        case .all: return "All time"
        }
    }
}
