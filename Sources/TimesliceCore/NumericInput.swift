import Foundation

/// Input filtering for the numeric fields, kept here so it's testable without a UI.
public enum NumericInput {

    /// Keep only what can be a budget in hours: digits, at most one decimal point, at most one digit
    /// after it.
    ///
    /// Applied as you TYPE rather than validated on commit. A field that accepts "4.55" and then
    /// silently stores 4.5 — or accepts "abc" and reverts — teaches you not to trust it; one that
    /// simply won't hold the bad character needs no explaining.
    ///
    /// A leading separator is dropped rather than becoming "0.5": someone typing ".5" has more likely
    /// mistyped than meant half an hour, and "5" is recoverable by looking at it.
    public static func hours(_ raw: String) -> String {
        var out = ""
        var seenSeparator = false
        var decimals = 0
        for ch in raw {
            if ch.isNumber {
                if seenSeparator {
                    // Second and later decimals are dropped, not rounded — rounding as you type
                    // fights the keystroke that's still arriving.
                    guard decimals < 1 else { continue }
                    decimals += 1
                }
                out.append(ch)
            } else if ch == "." || ch == "," {
                // A comma is what a European keyboard offers for the decimal point; treat it as one
                // rather than dropping it and leaving the digits fused ("1,5" → "15").
                guard !seenSeparator, !out.isEmpty else { continue }
                seenSeparator = true
                out.append(".")
            }
        }
        return out
    }
}
