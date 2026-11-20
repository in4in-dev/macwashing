import Foundation

/// The groups of the Startup section, in the order they are shown.
public enum StartupKind: String, Sendable, CaseIterable, Identifiable {
    /// Login items and background items apps register with macOS (System Settings ▸ General ▸ Login Items).
    case loginItem
    /// `~/Library/LaunchAgents`: runs in this user's session; the app switches it itself.
    case userAgent
    /// `/Library/LaunchAgents`: runs in every user's session; switched through the helper.
    case systemAgent
    /// `/Library/LaunchDaemons`: runs as root, without anyone logged in; switched through the helper.
    case systemDaemon

    public var id: String { rawValue }
}

/// Where an item was found.
public enum StartupSource: String, Sendable, Hashable {
    /// A plist in one of the LaunchAgents / LaunchDaemons folders: can be switched on and off.
    case launchJob
    /// `Contents/Library/LoginItems/*.app` inside an app (`SMLoginItemSetEnabled`, `SMAppService.loginItem`).
    case appLoginItem
    /// `Contents/Library/LaunchAgents/*.plist` inside an app (`SMAppService.agent`).
    case appAgent
    /// `Contents/Library/LaunchDaemons/*.plist` inside an app (`SMAppService.daemon`).
    case appDaemon
    /// A classic login item (the list System Events reads).
    case legacyLoginItem
}

/// Who an item belongs to.
public struct StartupOwner: Sendable, Hashable {
    public let name: String
    /// The app, for its icon and «Show in Finder».
    public let appURL: URL?
    public let bundleID: String?
    /// The app is not installed any more (known to the base, or only by the job's label).
    public let isRemoved: Bool

    public init(name: String, appURL: URL?, bundleID: String?, isRemoved: Bool = false) {
        self.name = name
        self.appURL = appURL
        self.bundleID = bundleID
        self.isRemoved = isRemoved
    }
}

/// Why an item cannot be switched from here.
public enum StartupToggleBlock: Sendable, Hashable {
    /// Registered by an app with macOS: only System Settings ▸ Login Items switches it.
    case systemSettings
    /// The job or its file does not pass the safety checks (`SafetyPolicy.userLaunchJobToggleAllowed` /
    /// `privilegedLaunchJobToggleAllowed`): Apple's label, MacWashing's own helper, a program in /System, a symlink,
    /// a label that differs from the file's, a plist others may write.
    case protected
}

/// One thing that starts automatically.
public struct StartupItem: Identifiable, Sendable, Hashable {
    /// `<kind>:<path>`.
    public let id: String
    public let kind: StartupKind
    public let source: StartupSource
    /// launchd label (the bundle id for login items).
    public let label: String?
    /// What to call it: the app the program is in, or the label.
    public let name: String
    /// The plist, or the bundle of a login item.
    public let url: URL
    /// `Program` or the first of `ProgramArguments`, as written.
    public let program: String?
    /// The innermost `.app` the program is in (`GoogleUpdater.app`), for the icon.
    public let programApp: URL?
    public let owner: StartupOwner?
    public let runAtLoad: Bool
    public let keepAlive: Bool
    /// Seconds.
    public let startInterval: Int?
    public let hasCalendar: Bool
    /// `Disabled` in the plist.
    public let disabledInPlist: Bool
    /// launchd's switch (`print-disabled`): true = disabled, false = enabled, nil = never set.
    public var override: Bool?
    /// Loaded into its launchd domain right now (`launchctl print` succeeds).
    public var isLoaded: Bool
    /// The program no longer exists (`LaunchJobs.programIsMissing`): what a removed app left behind.
    public let isBroken: Bool
    public let toggleBlock: StartupToggleBlock?

    public init(
        id: String, kind: StartupKind, source: StartupSource, label: String?, name: String, url: URL, program: String? = nil,
        programApp: URL? = nil, owner: StartupOwner? = nil, runAtLoad: Bool = false, keepAlive: Bool = false,
        startInterval: Int? = nil, hasCalendar: Bool = false, disabledInPlist: Bool = false, override: Bool? = nil,
        isLoaded: Bool = false, isBroken: Bool = false, toggleBlock: StartupToggleBlock? = nil
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.label = label
        self.name = name
        self.url = url
        self.program = program
        self.programApp = programApp
        self.owner = owner
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.startInterval = startInterval
        self.hasCalendar = hasCalendar
        self.disabledInPlist = disabledInPlist
        self.override = override
        self.isLoaded = isLoaded
        self.isBroken = isBroken
        self.toggleBlock = toggleBlock
    }

    /// Starts automatically. For a launch job launchd's switch wins over the plist's `Disabled`; for what an app
    /// registered with macOS the switch, or else whether it is loaded now; a classic login item is on while it is listed.
    public var isEnabled: Bool {
        switch source {
        case .launchJob: !(override ?? disabledInPlist)
        case .appLoginItem, .appAgent, .appDaemon: override.map { !$0 } ?? isLoaded
        case .legacyLoginItem: true
        }
    }

    /// Changing it needs an administrator (the helper).
    public var needsAdmin: Bool {
        kind == .systemAgent || kind == .systemDaemon || source == .appDaemon
    }

    public var canToggle: Bool { toggleBlock == nil && source == .launchJob }

    /// launchd domain it lives in: `gui/<uid>` for agents and login items, `system` for daemons.
    public func domain(uid: uid_t) -> String {
        kind == .systemDaemon || source == .appDaemon ? "system" : "gui/\(uid)"
    }

    /// Case-insensitive search over the name, label, owner and path.
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return [name, label, owner?.name, url.fsPath, program].compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// The filter above the list.
public enum StartupFilter: String, Sendable, CaseIterable, Hashable {
    case all, on, off, broken

    public func matches(_ item: StartupItem) -> Bool {
        switch self {
        case .all: true
        case .on: item.isEnabled
        case .off: !item.isEnabled
        case .broken: item.isBroken
        }
    }
}

/// One group of the list.
public struct StartupGroup: Identifiable, Sendable, Hashable {
    public let kind: StartupKind
    public let items: [StartupItem]
    public var id: String { kind.rawValue }

    public init(kind: StartupKind, items: [StartupItem]) {
        self.kind = kind
        self.items = items
    }

    /// Items grouped by kind in the section's order, filtered and searched; empty groups are left out. Broken items
    /// come first in a group, then by name.
    public static func make(_ items: [StartupItem], filter: StartupFilter = .all, query: String = "") -> [StartupGroup] {
        let shown = items.filter { filter.matches($0) && $0.matches(query) }
        return StartupKind.allCases.compactMap { kind in
            let own = shown.filter { $0.kind == kind }.sorted { a, b in
                if a.isBroken != b.isBroken { return a.isBroken }
                let order = a.name.localizedStandardCompare(b.name)
                return order == .orderedSame ? a.id < b.id : order == .orderedAscending
            }
            return own.isEmpty ? nil : StartupGroup(kind: kind, items: own)
        }
    }
}
