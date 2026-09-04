import SwiftUI
import TimesliceCore
import TimesliceUI

/// The one detail screen the dashboard keeps.
///
/// The dashboard answers "how is it going" in three cards; this answers "where did it go", which is a list and
/// therefore a poor fit for a card. Reached by tapping the Tracked card, per the agreed shape — allocations don't
/// need a detail because tapping one FILTERS the dashboard, and the timeline detail went with the rejected
/// vertical-canvas concept.

// MARK: - Breakdown

/// Where the time went, by task, project or tag — with a tap to filter.
struct BreakdownDetail: View {
    @ObservedObject var metrics: MetricsModel
    @Environment(\.dismiss) private var dismiss
    @State private var scope: Scope = .tasks

    enum Scope: String, CaseIterable, Identifiable {
        case tasks = "Tasks", projects = "Projects", tags = "Tags"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Scope", selection: $scope) {
                    ForEach(Scope.allCases) { s in Text(s.rawValue).tag(s) }
                }
                .pickerStyle(.segmented)

                if scope == .tags {
                    // Tags overlap, so their totals can exceed the range's tracked time. Said once, here,
                    // rather than leaving the sums looking broken.
                    Text("Tags overlap, so these can add up to more than the total.")
                        .font(Theme.metricCaption).foregroundStyle(.tertiary)
                }

                VStack(spacing: 12) { rows }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
            }
            .padding(16)
        }
        .background(Theme.page)
        .navigationTitle("Where time went")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var rows: some View {
        switch scope {
        case .tasks:
            let peak = metrics.data.taskTotals.map(\.seconds).max() ?? 1
            ForEach(metrics.data.taskTotals) { total in
                Button {
                    metrics.toggleFilter(.task(total.project.id), name: total.project.name)
                    dismiss()
                } label: {
                    BreakdownBar(name: total.project.name, seconds: total.seconds,
                                 fraction: peak > 0 ? total.seconds / peak : 0,
                                 colorHex: metrics.colorHexForTask(total.project.id))
                        .frame(minHeight: 40)
                }
                .buttonStyle(.plain)
            }
        case .projects:
            let peak = metrics.data.groupTotals.map(\.seconds).max() ?? 1
            ForEach(metrics.data.groupTotals) { total in
                Button {
                    guard let id = total.project?.id else { return }
                    metrics.toggleFilter(.project(id), name: total.name)
                    dismiss()
                } label: {
                    BreakdownBar(name: total.name, seconds: total.seconds,
                                 fraction: peak > 0 ? total.seconds / peak : 0,
                                 colorHex: total.colorHex)
                        .frame(minHeight: 40)
                }
                .buttonStyle(.plain)
                .disabled(total.project == nil)
            }
        case .tags:
            let peak = metrics.data.tagTotals.map(\.seconds).max() ?? 1
            ForEach(metrics.data.tagTotals) { total in
                Button {
                    guard let id = total.tag?.id else { return }
                    metrics.toggleFilter(.tag(id), name: total.name)
                    dismiss()
                } label: {
                    BreakdownBar(name: total.name, seconds: total.seconds,
                                 fraction: peak > 0 ? total.seconds / peak : 0,
                                 colorHex: total.colorHex)
                        .frame(minHeight: 40)
                }
                .buttonStyle(.plain)
                .disabled(total.tag == nil)
            }
        }
    }
}

/// A name, a duration and a proportional bar. The bar is the subject's own colour — the only saturated thing in
/// the row, which is the rule `Theme` opens with.
struct BreakdownBar: View {
    let name: String
    let seconds: TimeInterval
    let fraction: Double
    let colorHex: String

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(Color(hex: colorHex)).frame(width: 10, height: 10)
            Text(name).font(Theme.dashRow).lineLimit(1)
            Spacer(minLength: 8)
            Text(Format.compact(seconds))
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.metricTrack)
                    Capsule().fill(Color(hex: colorHex))
                        .frame(width: max(3, geo.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(width: 64, height: 8)
        }
        .frame(minHeight: 34)
    }
}
