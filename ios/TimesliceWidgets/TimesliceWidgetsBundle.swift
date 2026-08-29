import SwiftUI
import WidgetKit

/// Entry point for the widget extension. Only the Live Activity for now — a Home Screen widget
/// would have to *read* the database from this process, which forces an App Group container and
/// reintroduces the `0xdead10cc` risk (iOS terminates a suspended app holding a file lock on a
/// shared container, and a WAL sqlite connection is such a lock). The Live Activity avoids all of
/// that by rendering only what the app pushes into its content state.
@main
struct TimesliceWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TimerLiveActivity()
    }
}
