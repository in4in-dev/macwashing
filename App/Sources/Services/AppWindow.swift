import AppKit
import os
import SwiftUI

/// The main window, the Dock icon and the menu bar item.
///
/// - Started at login, the app shows no window and no Dock icon, only the menu bar item. The login launch is told by
///   the launch Apple event: an app the system opens as a login item (`SMAppService.mainApp`, the «Open at Login» list)
///   gets `kAEOpenApplication` whose `keyAEPropData` is `keyAELaunchedAsLogInItem`; one opened from Finder, the Dock or
///   `open` has no such property. The event is read while AppKit handles it — from the window as SwiftUI creates it,
///   and again in `applicationDidFinishLaunching` — whichever comes first.
/// - The close button quits the app while auto-clean is off. While it is on, the window closes, the Dock icon goes
///   (activation policy `.accessory`) and the app stays in the menu bar; `show()` brings both back.
@MainActor
enum AppWindow {
    private static let log = Logger(subsystem: "com.ovvi.MacWashing", category: "window")
    /// Set by Sparkle's silent install right before it relaunches the app from the menu bar: that relaunch stays there.
    static let relaunchHiddenKey = "relaunchHidden"

    /// The app model, once `MacWashingApp` made it (nil when the rules database did not open).
    static weak var model: AppModel?
    /// SwiftUI's `openWindow(id: "main")`, taken from the first view that has it (the main window, the menu bar item).
    static var openMain: (() -> Void)?

    /// This process started hidden: at login, or relaunched by a silent update from the menu bar.
    private(set) static var startedHidden = false
    private static var launchEventRead = false
    private static var launchFinished = false
    private static weak var main: NSWindow?
    /// The main window is on screen (not closed).
    private(set) static var isMainOpen = false
    private static var closeObserver: NSObjectProtocol?
    /// The hidden launch closes the window SwiftUI opened anyway: that close must not quit.
    private static var closingHidden = false

    // MARK: Launch

    /// Reads the launch event while AppKit is handling it (it is `currentAppleEvent` only then).
    private static func readLaunchEvent() {
        guard !launchEventRead, let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEOpenApplication) else { return }
        launchEventRead = true
        if event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            startedHidden = true
            log.info("launched as a login item")
        }
    }

    /// `applicationDidFinishLaunching`: the last chance to read the launch event; hides what is already shown.
    static func finishLaunching() {
        readLaunchEvent()
        launchEventRead = true
        let defaults = UserDefaults.standard
        if let relaunch = defaults.object(forKey: relaunchHiddenKey) as? Date {
            defaults.removeObject(forKey: relaunchHiddenKey)
            if Date().timeIntervalSince(relaunch) < 600 { startedHidden = true }
        }
        #if DEBUG
        // `MW_LOGIN_LAUNCH=1`: start as if at login (no window, menu bar only).
        if ProcessInfo.processInfo.environment["MW_LOGIN_LAUNCH"] == "1" { startedHidden = true }
        #endif
        launchFinished = true
        guard startedHidden, model != nil else {
            // LSUIElement (Info.plist): every launch starts without a Dock icon, so a hidden one (login, a silent update)
            // never flashes it; a normal launch gets the icon here and comes to the front.
            NSApp.setActivationPolicy(.regular)
            AppIconManager.apply()
            NSApp.activate()
            return
        }
        NSApp.setActivationPolicy(.accessory)
        if let main, isMainOpen { closeHidden(main) }
    }

    // MARK: The main window

    /// Called by the main window's content once it is in its window.
    static func attach(_ window: NSWindow) {
        readLaunchEvent()
        guard main !== window else { return }
        main = window
        isMainOpen = true
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { mainWillClose() }
        }
        // The first window of a hidden launch: never seen, closed right away.
        if startedHidden, !shownByUser, model != nil {
            window.alphaValue = 0
            DispatchQueue.main.async { closeHidden(window) }
        }
    }

    /// The user (or the menu bar item) opened the window at least once in this process.
    private static var shownByUser = false

    private static func closeHidden(_ window: NSWindow) {
        closingHidden = true
        window.close()
        window.alphaValue = 1
        closingHidden = false
    }

    private static func mainWillClose() {
        isMainOpen = false
        main = nil
        if closingHidden { return }
        guard let model else {
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }
        if model.autoClean.keepsRunningInMenuBar {
            // Auto-clean is on: the window goes, the app stays in the menu bar without a Dock icon.
            NSApp.setActivationPolicy(.accessory)
            log.info("window closed: staying in the menu bar")
        } else {
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// ⌘Q in the app menu does what the close button does: with auto-clean on the window goes and the app stays in the
    /// menu bar (or only in the background, its icon hidden), otherwise it quits. The other ways out (the menu bar item's
    /// «Закрыть программу», the Dock, logging out, Sparkle's relaunch) still quit for real.
    static func quitFromMenu() {
        guard let main, isMainOpen, model?.autoClean.keepsRunningInMenuBar == true else {
            NSApp.terminate(nil)
            return
        }
        main.close()
    }

    /// Brings back the Dock icon and the window (opening a new one if it was closed).
    static func show() {
        shownByUser = true
        NSApp.setActivationPolicy(.regular)
        AppIconManager.apply()
        NSApp.activate()
        if let main, isMainOpen {
            if main.isMiniaturized { main.deminiaturize(nil) }
            main.makeKeyAndOrderFront(nil)
        } else if let openMain {
            openMain()
        } else {
            log.error("no way to open the main window")
        }
    }

    /// The app lives only in the menu bar now: no main window on screen.
    static var inMenuBarOnly: Bool { !isMainOpen }
}

/// Hands the window a view is in to `AppWindow` as soon as it has one (before it is first drawn).
struct MainWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Reader() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Reader: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            MainActor.assumeIsolated { AppWindow.attach(window) }
        }
    }
}

/// Takes SwiftUI's `openWindow` for `AppWindow.show()` from whatever view appears first.
struct OpenWindowCatcher: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            guard AppWindow.openMain == nil else { return }
            let open = openWindow
            AppWindow.openMain = { open(id: "main") }
        }
    }
}
