// Timeslice — a time tracker for fast, restless, multitasking brains.
// Copyright (C) 2026 Ramana
//
// This program is free software: you can redistribute it and/or modify it under the terms of the
// GNU General Public License as published by the Free Software Foundation, either version 3 of
// the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
// without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
// See the GNU General Public License for more details: <https://www.gnu.org/licenses/>.

import AppKit

@main
@MainActor
enum TimesliceMain {
    static func main() {
        let application = NSApplication.shared
        let appDelegate = AppDelegate()
        application.delegate = appDelegate
        // .regular gives a Dock icon and ⌘-Tab presence (the user wants to switch to it that
        // way). The menu-bar item + popover remain the primary interaction.
        application.setActivationPolicy(.regular)
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}
