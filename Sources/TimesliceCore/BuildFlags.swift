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
/// The `UserDefaults` escape hatch is for the one case compiling it out can't serve: getting a
/// diagnosis out of a shipped build someone else is running.
public enum BuildFlags {
    public static var developerToolsEnabled: Bool {
        #if TIMESLICE_DEV
        return true
        #elseif DEBUG
        return true
        #else
        return UserDefaults.standard.bool(forKey: "TimesliceDeveloperTools")
        #endif
    }
}
