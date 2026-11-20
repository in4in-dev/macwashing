import AppKit
import CoreServices
import Foundation
import MacWashingKit

/// Classic login items, as System Events lists them. There is no public API to list other apps' login items, and
/// asking System Events needs an Automation permission: they are read only when that permission is already granted and
/// System Events is already running, so opening the Startup section never shows a permission prompt or starts anything.
enum LegacyLoginItems {
    static let systemEvents = "com.apple.systemevents"

    /// One script at a time, on its own thread: an Apple event round trip to System Events can take a while and must
    /// not hold the main thread (AppleScript runs on any thread as long as one script is not used by two at once).
    private static let queue = DispatchQueue(label: "MacWashing.legacyLoginItems", qos: .userInitiated)

    static func read() async -> [URL] {
        guard await BlockingWork.run(.measure, { _ in mayAsk() }) else { return [] }
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: run()) }
        }
    }

    /// True only when macOS already lets MacWashing send Apple events to System Events (never asks the user).
    private static func mayAsk() -> Bool {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: systemEvents).isEmpty else { return false }
        let target = NSAppleEventDescriptor(bundleIdentifier: systemEvents)
        guard let desc = target.aeDesc else { return false }
        return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false) == noErr
    }

    private static func run() -> [URL] {
        var error: NSDictionary?
        let script = NSAppleScript(source: #"tell application id "com.apple.systemevents" to get the path of every login item"#)
        guard let result = script?.executeAndReturnError(&error), error == nil else { return [] }
        let paths: [String] = if result.numberOfItems > 0 {
            (1...result.numberOfItems).compactMap { result.atIndex($0)?.stringValue }
        } else {
            [result.stringValue].compactMap { $0 }
        }
        return paths.filter { $0.hasPrefix("/") }.map { URL(filePath: $0) }
    }
}
