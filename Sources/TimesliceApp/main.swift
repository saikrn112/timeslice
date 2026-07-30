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
