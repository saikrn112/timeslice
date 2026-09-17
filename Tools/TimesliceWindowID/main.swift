import CoreGraphics
import Foundation

/// Prints the window id of a running Timeslice window, largest first.
///
/// Exists for `scripts/shot.sh`: `screencapture -l` needs a window id, and no shell command maps an app
/// name to one. Listing windows needs no TCC grant; only capturing an image does.
///
/// Takes an optional owner pid, and that argument is the whole point: the installed copy in
/// /Applications is usually running too, and matching on the name alone captured ITS window — a
/// screenshot of the previous build, which is worse than no screenshot because it looks like evidence.
let wantedPID = CommandLine.arguments.dropFirst().first.flatMap { Int($0) }

// `.optionAll`, not `.optionOnScreenOnly`: a window that has just been ordered front is briefly not
// reported as on-screen, and the wait loop then times out on a window that exists.
let options: CGWindowListOption = [.optionAll]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
let mine = windows
    // An UNBUNDLED binary reports its owner name as the executable, "TimesliceApp", not "Timeslice".
    // Matching only the bundled name found no window at all and looked like a launch failure.
    .filter { name in
        let owner = name[kCGWindowOwnerName as String] as? String ?? ""
        return owner == "Timeslice" || owner == "TimesliceApp"
    }
    .filter { wantedPID == nil || ($0[kCGWindowOwnerPID as String] as? Int) == wantedPID }
    .compactMap { window -> (Int, Double)? in
        guard let id = window[kCGWindowNumber as String] as? Int,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
              width > 300, height > 300 else { return nil }   // skip the menu-bar popover
        return (id, width * height)
    }
    .sorted { $0.1 > $1.1 }
for (id, _) in mine { print(id) }
