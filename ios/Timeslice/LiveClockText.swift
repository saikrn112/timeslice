import SwiftUI
import TimesliceCore
import TimesliceUI

/// A ticking clock that can show **milliseconds**, like the Mac's.
///
/// ## Why this exists rather than `Text(timerInterval:)`
///
/// `Text(timerInterval:pauseTime:countsDown:showsHours:)` is drawn and advanced by the system, which is
/// exactly right for the Dynamic Island and Lock Screen — it keeps counting while this process is
/// suspended or dead. But its only formatting knob is `showsHours`: there is **no** subsecond option, so
/// it cannot match the Mac, which shows `1:23.45` on the running row.
///
/// So in-app clocks drive from our own 10fps timer. That's affordable here and nowhere else: the app is
/// on screen, whereas the widget extension has no run loop of its own.
///
/// Mirrors the Mac's `LiveTimeText` deliberately — an `ObservableObject` holding only the fast value, so
/// a 10fps change re-renders this label and nothing else. Charts and lists observe the model, which
/// changes rarely.
@MainActor
final class TickClock: ObservableObject {
    static let shared = TickClock()

    /// Republished 10× a second while any clock is on screen.
    @Published private(set) var now = Date()

    private var timer: Timer?
    /// How many visible clocks are driving from this. The timer stops at zero, so a screen with no
    /// running task costs nothing.
    private var subscribers = 0

    private init() {}

    func subscribe() {
        subscribers += 1
        guard timer == nil else { return }
        // 10fps: the Mac's rate. Enough for a two-digit ms field to look continuous, a third of the
        // cost of 30fps, and it only touches `now`.
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
    }

    func unsubscribe() {
        subscribers = max(0, subscribers - 1)
        guard subscribers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }
}

/// Elapsed time from `origin`, ticking, optionally with milliseconds.
///
/// `origin` is a backdated instant (`TimerModel.liveOrigin`) so the rendered value is
/// `committed today + this run` — the same quantity the island and the Mac show, from the same maths in
/// `TimerDisplay`. Nothing is accumulated here; the value is always derived, so a missed tick or a
/// suspended app can't make it drift.
struct LiveClockText: View {
    let origin: Date
    var showsMilliseconds = true

    @ObservedObject private var clock = TickClock.shared

    var body: some View {
        let elapsed = max(0, clock.now.timeIntervalSince(origin))
        Text(showsMilliseconds ? Format.durationMs(elapsed) : Format.duration(elapsed))
            .monospacedDigit()
            .onAppear { clock.subscribe() }
            .onDisappear { clock.unsubscribe() }
    }
}
