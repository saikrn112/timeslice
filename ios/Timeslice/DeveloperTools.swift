import Foundation
import TimesliceCore

/// Whether this build shows the developer-facing tools: the Feedback tab and the Diagnostics sheet.
///
/// Both exist to develop the app rather than to use it. Feedback is a bug tracker whose only reader
/// is the developer — shipping it would hand every user a list of someone else's complaints and a
/// queue nobody reads — and Diagnostics prints memory footprints, MetricKit payloads and sync
/// internals that are noise at best.
///
/// Separate from `TimesliceCore.BuildFlags` on purpose, and not a duplicate by accident: Xcode's
/// per-target `SWIFT_ACTIVE_COMPILATION_CONDITIONS` do NOT reach a SwiftPM package's targets, so a
/// `#if TIMESLICE_DEV` written inside Core can never be true in this build no matter what the
/// project sets. The Mac app defines it for every target at once (`swift build -Xswiftc -D…`), which
/// is why Core can answer for itself there. Each target has to answer for its own build.
/// A compile-time CONSTANT, with no runtime override — and used in an `#if` at the entry points, not
/// merely an `if`. A runtime check reads as gated while leaving every view compiled into the binary
/// and callable by anything that reaches it directly, which is the opposite of what was asked for.
enum DeveloperTools {
    #if TIMESLICE_DEV || DEBUG
    static let enabled = true
    #else
    static let enabled = false
    #endif
}
