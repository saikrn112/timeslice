import Foundation

/// Whether this build exposes the developer-facing tools: the feedback list and the sync
/// diagnostics.
///
/// Both exist to develop the app, not to use it. Feedback is a bug tracker with the developer as its
/// only reader — shipping it would give every user a list of someone else's complaints and a way to
/// file into a queue nobody reads — and the diagnostics print device ids and sync internals that are
/// noise at best.
///
/// Compiled OUT of a release build rather than hidden at runtime, so there's no dead UI to reach by
/// accident and nothing to gate wrong. `scripts/build_native_app.sh` defines `TIMESLICE_DEV` for the
/// builds installed during development; a genuine release build simply omits it.
///
/// A compile-time CONSTANT, with no runtime override. An earlier version fell back to a
/// `UserDefaults` key in release builds so a shipped app could be talked into showing its
/// diagnostics — which made the whole thing a runtime check, left every view linked into the binary,
/// and gave a release build a way in. Every install of this app is a development build, so the hatch
/// bought nothing and cost exactly the property that was asked for.
///
/// Use it in an `#if` at the entry points, not just an `if`: a runtime branch keeps the UI in the
/// binary and reachable by anything that calls it directly.
public enum BuildFlags {
    #if TIMESLICE_DEV || DEBUG
    public static let developerToolsEnabled = true
    #else
    public static let developerToolsEnabled = false
    #endif
}
