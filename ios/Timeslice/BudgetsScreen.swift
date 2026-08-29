import SwiftUI

/// Placeholder — built in phase 3 (§3.1).
struct BudgetsScreen: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Budgets", systemImage: "target",
                description: Text("Coming in phase 3: one row per budget with its goal bar, "
                                  + "inline percentage and sparkline."))
                .navigationTitle("Budgets")
        }
    }
}
