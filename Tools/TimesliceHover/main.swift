import CoreGraphics
import Foundation

/// Moves the mouse to a point, so `scripts/shot.sh` can photograph a tooltip.
///
/// `.help()` tooltips only exist on hover, and a screenshot of a page nobody is pointing at can't show
/// whether they work or say the right thing. `CGWarpMouseCursorPosition` needs no permission.
///
/// Usage: TimesliceHover <x> <y>   (screen coordinates, origin top-left)
let args = CommandLine.arguments.dropFirst().compactMap { Double($0) }
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: TimesliceHover <x> <y>\n".utf8))
    exit(2)
}
let point = CGPoint(x: args[0], y: args[1])
CGWarpMouseCursorPosition(point)
CGAssociateMouseAndMouseCursorPosition(1)

// A warp moves the cursor without telling anyone. AppKit starts its tooltip timer from a mouse-MOVED
// event, so a warp alone leaves the pointer sitting over a view that never learned it was there.
// Two events a moment apart, because the timer restarts on movement and needs a still pointer after it.
for offset in [1.0, 0.0] {
    if let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                           mouseCursorPosition: CGPoint(x: point.x + offset, y: point.y),
                           mouseButton: .left) {
        event.post(tap: .cghidEventTap)
    }
    usleep(120_000)
}
