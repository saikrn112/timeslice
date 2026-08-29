import SwiftUI
import TimesliceCore
import TimesliceUI

/// Budgets: one row per target with its goal bar, inline percentage and trend.
///
/// Every figure comes from `BudgetRows.build` — the same composition the Mac's Budgets section uses,
/// measuring each budget against **its own period** rather than the range you're browsing. Nothing
/// here recomputes any of it.
///
/// The Mac shows two bars per row (the goal, and the target pro-rated onto the viewed range). This
/// shows one: there isn't width on a phone for two bars plus the captions explaining why there are
/// two, and the goal bar is the one that answers "am I on track". The range control still re-scopes
/// the trend sparkline.
struct BudgetsScreen: View {
    @ObservedObject private var model = TimerModel.shared
    @State private var unit: RangeUnit = .week
    @State private var rows: [BudgetRows.Row] = []
    @State private var addingBudget = false
    @State private var editingTags = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Range", selection: $unit) {
                        ForEach(RangeUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                if rows.isEmpty {
                    ContentUnavailableView(
                        "No budgets", systemImage: "target",
                        description: Text("Set a budget on a task, a project or a tag — "
                                          + "“at least 30h a week”, “at most 5h a day”."))
                } else {
                    ForEach(rows) { row in
                        BudgetRowView(row: row)
                            .swipeActions {
                                Button("Delete", role: .destructive) { delete(row) }
                            }
                    }
                }
            }
            .navigationTitle("Budgets")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("New budget…", systemImage: "plus") { addingBudget = true }
                        Button("Edit tags…", systemImage: "tag") { editingTags = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $addingBudget, onDismiss: rebuild) { BudgetEditorSheet() }
            .sheet(isPresented: $editingTags, onDismiss: rebuild) { TagEditorSheet() }
            .onAppear(perform: rebuild)
            .onChange(of: unit) { _, _ in rebuild() }
            // The running timer moves these numbers, so rebuild when it changes.
            .onChange(of: model.running?.projectID) { _, _ in rebuild() }
            .refreshable { model.reload(); rebuild() }
        }
    }

    private func rebuild() {
        guard let store = model.storeIfLoaded else { return }
        let now = Date()
        let range = DateRange.resolve(unit: unit, anchor: now,
                                      earliest: try? store.earliestIntervalStart())
        // A superset of intervals — each window inside `build` clips them itself.
        rows = BudgetRows.build(
            targets: (try? store.listTargets()) ?? [],
            tasks: model.allTasks,
            groups: model.groups,
            tags: model.allTags,
            tagIDsByTask: (try? store.effectiveTagIDsByTask()) ?? [:],
            intervals: (try? store.intervals()) ?? [],
            viewedRange: range,
            now: now)
    }

    private func delete(_ row: BudgetRows.Row) {
        try? model.storeIfLoaded?.deleteTarget(id: row.progress.target.id)
        rebuild()
    }
}

private struct BudgetRowView: View {
    let row: BudgetRows.Row

    private var p: TargetProgress { row.progress }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle().fill(Color(hex: row.colorHex)).frame(width: 9, height: 9)
                Text(p.name).font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                // States the budget itself — "≥ 30h / week". Showing only the direction leaves the
                // row unable to say what it's measuring against.
                Text("\(p.target.direction.symbol) \(BudgetRows.duration(p.target.seconds))"
                     + " / \(p.target.period.rawValue)")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            // The shared InlineBar — percentage centred inside, legible at any fill.
            InlineBar(fraction: min(max(p.percent / 100, 0), 1),
                      label: "\(BudgetRows.duration(p.actualSeconds)) · \(Int(p.percent.rounded()))%",
                      fill: verdictColor)

            HStack(spacing: 8) {
                Label(verdictText, systemImage: verdictIcon)
                    .font(.caption2).foregroundStyle(verdictColor)
                Spacer()
                if let need = p.requiredPerDaySeconds, need > 0 {
                    Text("needs \(BudgetRows.duration(need))/day")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Sparkline(values: row.sparkline, tint: Color(hex: row.colorHex))
                    .frame(width: 74, height: 16)
            }
        }
        .padding(.vertical, 3)
    }

    /// Trouble is red, behind is orange, on-pace and met are green — matching the Mac's verdicts.
    private var verdictColor: Color {
        switch p.verdict {
        case .over: return .red
        case .behind: return .orange
        case .onPace, .met: return .green
        }
    }

    private var verdictText: String {
        switch p.verdict {
        case .over: return "over by \(BudgetRows.duration(abs(p.deltaSeconds)))"
        case .behind: return "behind"
        case .onPace: return "on pace"
        case .met: return "met"
        }
    }

    private var verdictIcon: String {
        switch p.verdict {
        case .over: return "exclamationmark.triangle.fill"
        case .behind: return "arrow.down.right"
        case .onPace: return "arrow.up.right"
        case .met: return "checkmark.circle.fill"
        }
    }
}
