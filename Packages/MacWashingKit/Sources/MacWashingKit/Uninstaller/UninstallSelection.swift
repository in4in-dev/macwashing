import Foundation

/// What the Uninstaller has checked: item ids (paths; an app's bundle item has the app's id), the shared items checked by
/// themselves, and the apps ticked before their related files were found.
///
/// - The app's check (and «Выбрать неиспользуемые») takes the `recommended` items: found by bundle id, not «likely», not
///   shared. «Выбрать всё» over an app's files takes `everything` but its shared items.
/// - Shared items (a suite's folder and common files) are never taken by a scope: they follow the apps using them
///   (`sync`) — checked once this app and every other app using them are checked, unchecked again when one stops being.
/// - An app ticked while its files are still being found is `pending`: it shows as checked at once, and its files get the
///   scope it was ticked with as soon as they arrive (`loaded`). Removal waits while anything is pending
///   (`isWaiting`): the app's files are not known yet, so neither its size nor what removing it takes is.
public struct UninstallSelection: Sendable, Equatable {
    public enum Scope: Sendable, Equatable {
        /// What selecting the whole app takes by default: no «likely» and no shared items.
        case recommended
        /// «Выбрать всё»: every item the user may tick by hand, shared items aside.
        case everything
    }

    public enum State: Sendable, Equatable { case off, mixed, on }

    public private(set) var checked: Set<String> = []
    /// Shared items checked by `sync`, so that unchecking an app does not take back what the user ticked by hand.
    private var autoShared: Set<String> = []
    /// App id → scope: ticked before its related files were found.
    public private(set) var pending: [String: Scope] = [:]

    public init() {}

    /// Something was ticked while its files were still being found.
    public var isWaiting: Bool { !pending.isEmpty }

    public func isPending(_ appID: String) -> Bool { pending[appID] != nil }

    public func contains(_ item: RelatedItem) -> Bool { checked.contains(item.id) }

    public static func takes(_ item: RelatedItem, _ scope: Scope) -> Bool {
        guard item.sharedWith.isEmpty else { return false }
        return scope == .everything || !item.isLikely
    }

    /// The app's check: `on` once every recommended item is checked (likely and shared ones do not count against it),
    /// and while it waits for its files.
    public func state(of appID: String, items: [RelatedItem]?) -> State {
        if isPending(appID) { return .on }
        guard let items, !items.isEmpty else { return .off }
        let selected = items.filter { checked.contains($0.id) }.count
        if selected == 0 { return .off }
        let recommended = items.filter { Self.takes($0, .recommended) }.count
        return selected >= recommended ? .on : .mixed
    }

    /// Every item «Выбрать всё» takes is checked: the button offers «Снять всё».
    public func hasEverything(_ items: [RelatedItem]) -> Bool {
        let all = items.filter { Self.takes($0, .everything) }
        return !all.isEmpty && all.allSatisfy { checked.contains($0.id) }
    }

    /// Checks the app's items in `scope`; with its files not found yet (`items == nil`), remembers it until `loaded`.
    public mutating func select(_ appID: String, items: [RelatedItem]?, scope: Scope, related: [String: [RelatedItem]]) {
        guard let items else {
            pending[appID] = scope
            return
        }
        pending[appID] = nil
        for item in items where Self.takes(item, scope) { checked.insert(item.id) }
        sync(related)
    }

    /// Unchecks every item of the app, shared ones too, and forgets a tick waiting for its files.
    public mutating func deselect(_ appID: String, items: [RelatedItem]?, related: [String: [RelatedItem]]) {
        pending[appID] = nil
        for item in items ?? [] {
            checked.remove(item.id)
            autoShared.remove(item.id)
        }
        sync(related)
    }

    public mutating func toggle(_ item: RelatedItem, related: [String: [RelatedItem]]) {
        if checked.contains(item.id) { checked.remove(item.id) } else { checked.insert(item.id) }
        autoShared.remove(item.id)
        sync(related)
    }

    /// The app's related files have arrived (they are in `related`): a tick waiting for them is applied now.
    public mutating func loaded(_ appID: String, related: [String: [RelatedItem]]) {
        if let scope = pending[appID], let items = related[appID] {
            select(appID, items: items, scope: scope, related: related)
        } else {
            sync(related)
        }
    }

    /// The app's files will never arrive (it is gone from the list): its waiting tick is dropped.
    public mutating func forget(_ appID: String) {
        pending[appID] = nil
    }

    public mutating func clear() {
        checked = []
        autoShared = []
        pending = [:]
    }

    /// A shared item is checked once its app and every other app using it are checked (the bundle item's id is the
    /// app's id), and unchecked again when one of them is not.
    private mutating func sync(_ related: [String: [RelatedItem]]) {
        for (appID, items) in related {
            for item in items where !item.sharedWith.isEmpty {
                let ready = checked.contains(appID) && item.sharedWith.allSatisfy(checked.contains)
                if ready, !checked.contains(item.id) {
                    checked.insert(item.id)
                    autoShared.insert(item.id)
                } else if !ready, autoShared.contains(item.id) {
                    checked.remove(item.id)
                    autoShared.remove(item.id)
                }
            }
        }
    }
}
