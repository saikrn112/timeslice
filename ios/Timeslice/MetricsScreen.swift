import SwiftUI

/// Placeholder — built in phase 4 (§3.3). Deliberately says so rather than showing an empty chart,
/// so a screenshot of this build can't be mistaken for a broken Metrics screen.
struct MetricsScreen: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Metrics", systemImage: "chart.bar",
                description: Text("Coming in phase 4: the day timeline, Where time went, "
                                  + "Sessions and the weekday pattern."))
                .navigationTitle("Metrics")
        }
    }
}
