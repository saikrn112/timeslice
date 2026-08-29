import SwiftUI
import TimesliceCore
import TimesliceUI

/// Create a budget: pick a subject, a direction, a period and an amount.
///
/// A budget can point at a **task, a project or a tag** — that's the whole reason the tag layer
/// exists. A per-project budget then needs no tag, and a cross-project one needs no restructuring.
struct BudgetEditorSheet: View {
    @ObservedObject private var model = TimerModel.shared
    @Environment(\.dismiss) private var dismiss

    private enum Kind: String, CaseIterable, Identifiable {
        case task = "Task", project = "Project", tag = "Tag"
        var id: String { rawValue }
    }

    @State private var kind: Kind = .project
    @State private var subjectID: Int64?
    @State private var direction: Target.Direction = .atLeast
    @State private var period: Target.Period = .week
    @State private var hours: Double = 10

    var body: some View {
        NavigationStack {
            Form {
                Section("Applies to") {
                    Picker("Kind", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: kind) { _, _ in subjectID = defaultSubjectID }

                    Picker("Subject", selection: $subjectID) {
                        Text("Choose…").tag(Int64?.none)
                        ForEach(options, id: \.id) { option in
                            Text(option.name).tag(Int64?.some(option.id))
                        }
                    }
                }

                Section("Budget") {
                    Picker("Direction", selection: $direction) {
                        // "≥ at least" / "≤ at most" — the symbol alone is too terse in a form.
                        ForEach(Target.Direction.allCases, id: \.self) { d in
                            Text("\(d.symbol)  \(d == .atLeast ? "at least" : "at most")").tag(d)
                        }
                    }
                    Picker("Per", selection: $period) {
                        ForEach(Target.Period.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Stepper(value: $hours, in: 0.5...200, step: 0.5) {
                        LabeledContent("Hours", value: BudgetRows.duration(hours * 3600))
                    }
                }

                Section {
                    // Reads the budget back as a sentence, so the direction/period combination is
                    // unambiguous before saving.
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(subjectID == nil)
                }
            }
            .onAppear { subjectID = defaultSubjectID }
        }
    }

    private struct Option: Identifiable { let id: Int64; let name: String }

    private var options: [Option] {
        switch kind {
        case .task: return model.tasks.map { Option(id: $0.id, name: $0.name) }
        case .project: return model.groups.map { Option(id: $0.id, name: $0.name) }
        case .tag: return model.allTags.map { Option(id: $0.id, name: $0.name) }
        }
    }

    private var defaultSubjectID: Int64? { options.first?.id }

    private var summary: String {
        let who = options.first { $0.id == subjectID }?.name ?? "…"
        let verb = direction == .atLeast ? "at least" : "at most"
        return "Spend \(verb) \(BudgetRows.duration(hours * 3600)) on \(who) per \(period.rawValue)."
    }

    private func save() {
        guard let subjectID, let store = model.storeIfLoaded else { return }
        let subject: TargetSubject = {
            switch kind {
            case .task: return .task(subjectID)
            case .project: return .project(subjectID)
            case .tag: return .tag(subjectID)
            }
        }()
        _ = try? store.setTarget(subject: subject, seconds: hours * 3600,
                                 direction: direction, period: period)
        model.reload()
        dismiss()
    }
}
