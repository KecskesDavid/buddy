import AppKit

/// AppKit entry point for things SwiftUI can't do on its own:
/// overlay panels (drawing layer, answer bubble), global hotkey, mouse tracking.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writing to `claude`'s stdin after it exited must not kill Buddy.
        signal(SIGPIPE, SIG_IGN)
        AppModel.shared.start()
    }
}
