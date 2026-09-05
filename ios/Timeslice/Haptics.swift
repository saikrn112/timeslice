import UIKit

/// A tap you can feel.
///
/// Switching tasks is the app's most repeated action and the one the user reported as high-friction.
/// Much of that friction is uncertainty — did the tap land? Did it switch, or pause? A short impulse
/// answers that without looking, which is the whole point on a phone.
///
/// Distinct weights so the three outcomes are tellable apart with the phone in a pocket:
/// starting is firmer than switching, pausing is the lightest.
enum Haptics {
    static func started() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func switched() { UISelectionFeedbackGenerator().selectionChanged() }
    static func paused() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}
