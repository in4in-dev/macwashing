import AppKit

/// Launch, reopen and the last window closing: the app may live in the menu bar without a window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A launch at login stays in the menu bar without a window (Services/AppWindow.swift).
        AppWindow.finishLaunching()
        // Before onboarding registers the helper from this bundle.
        if !AppWindow.startedHidden { AppLocation.offerMoveIfNeeded() }
        AppWindow.model?.launch()
    }

    /// The window decides by itself (`AppWindow`): it quits while auto-clean is off, stays in the menu bar while on.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Opened again from Finder, the Dock or Spotlight while living in the menu bar: the window comes back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard AppWindow.model != nil else { return true }
        if !hasVisibleWindows || AppWindow.inMenuBarOnly { AppWindow.show() }
        return false
    }
}
