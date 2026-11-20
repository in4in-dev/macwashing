import Foundation

/// Puts a category's folders of one owner (an app, a vendor, macOS) under one group, titled and shown as that owner.
enum OwnerGrouping {
    struct Item {
        let entry: JunkEntry
        let owner: FolderOwner?
        /// The folder listed item by item (`Google`) this came from: without an owner, it stays grouped under it.
        var folder: URL?
    }

    static func group(_ items: [Item]) -> [JunkEntry] {
        var order: [String] = []
        var byKey: [String: [Item]] = [:]
        var loose: [JunkEntry] = []
        for item in items {
            let key = item.owner?.groupKey ?? item.folder.map { "folder:" + $0.fsPath }
            guard let key else {
                loose.append(item.entry)
                continue
            }
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(item)
        }
        return loose + order.compactMap { key in
            guard let members = byKey[key], let first = members.first else { return nil }
            if let owner = first.owner { return entry(for: owner, members.map(\.entry)) }
            guard let folder = first.folder else { return nil }
            // No owner: the folder's own group, its items named as in it.
            let children = members.map { retitled($0.entry, $0.entry.url.lastPathComponent) }.sorted { $0.size > $1.size }
            return JunkEntry(
                url: folder, title: folder.lastPathComponent, size: children.reduce(0) { $0 + $1.size }, kind: .folder,
                isGray: children.allSatisfy(\.isGray), requiresQuit: children.lazy.compactMap(\.requiresQuit).first,
                needsPrivileges: children.contains(where: \.needsPrivileges), children: children
            )
        }
    }

    static func retitled(_ entry: JunkEntry, _ title: String) -> JunkEntry {
        JunkEntry(url: entry.url, title: title, size: entry.size, kind: entry.kind, isGray: entry.isGray, requiresQuit: entry.requiresQuit,
                  needsPrivileges: entry.needsPrivileges, action: entry.action, children: entry.children,
                  ownerBundleID: entry.ownerBundleID, ownerNote: entry.ownerNote)
    }

    /// Title, icon and note of an owner's group.
    static func look(of owner: FolderOwner) -> (title: String, kind: JunkEntryKind, note: JunkOwnerNote?, bundleID: String?) {
        switch owner {
        case .app(let app):
            return (app.name, .app(bundleID: app.bundleID, appURL: app.url), nil, app.bundleID)
        case .vendor(let vendor):
            return (vendor.name, .vendor(name: vendor.name, appURLs: vendor.apps.prefix(3).map(\.url)), nil, nil)
        case .removed(let removed):
            if let newer = removed.olderVersionOf {
                return (newer.name, .app(bundleID: newer.bundleID, appURL: newer.url), .olderVersion, nil)
            }
            return (removed.name, .folder, nil, nil)
        case .macOS:
            return ("macOS", .system, nil, nil)
        case .shared(let name):
            return (name, .folder, .sharedComponent, nil)
        case .developerTool:
            // The UI names the group (it is localized there).
            return ("Developer Tools", .developerTools, nil, nil)
        }
    }

    /// One folder shows its owner (with the owner's icon), or its own name for macOS and shared components, which say
    /// nothing by themselves; several make a group.
    static func entry(for owner: FolderOwner, _ members: [JunkEntry]) -> JunkEntry {
        let look = look(of: owner)
        if members.count == 1, let only = members.first, only.children.isEmpty {
            let keepsName: Bool = switch owner {
            case .macOS, .shared, .developerTool: true
            default: false
            }
            return JunkEntry(
                url: only.url, title: keepsName ? only.title : look.title, size: only.size, kind: look.kind,
                isGray: only.isGray, requiresQuit: only.requiresQuit, needsPrivileges: only.needsPrivileges, action: only.action,
                ownerBundleID: only.ownerBundleID ?? look.bundleID, ownerNote: look.note
            )
        }
        let children = members.flatMap(\.leaves).sorted { $0.size > $1.size }
        let first = children[0]
        return JunkEntry(
            url: first.url.deletingLastPathComponent().appending(path: look.title), title: look.title,
            size: children.reduce(0) { $0 + $1.size }, kind: look.kind,
            isGray: children.allSatisfy(\.isGray), requiresQuit: children.lazy.compactMap(\.requiresQuit).first,
            needsPrivileges: children.contains(where: \.needsPrivileges), children: children,
            ownerBundleID: look.bundleID, ownerNote: look.note
        )
    }
}
