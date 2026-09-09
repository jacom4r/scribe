import AppKit

/// Finalizes an in-progress recording when the app is terminated by the
/// system (logout, restart, `osascript quit`) rather than from the menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by AppState; called before termination proceeds.
    static var terminationHandler: (() -> Void)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppDelegate.terminationHandler?()
        return .terminateNow
    }
}
