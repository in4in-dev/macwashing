import Darwin
import Foundation

/// XPC interface of the privileged helper (a launchd daemon registered with `SMAppService`).
@objc public protocol MacWashingHelperProtocol {
    /// Removes items (or moves them to the client user's Trash). Replies with path → error for failures.
    func removeItems(atPaths paths: [String], toTrash: Bool, reply: @escaping @Sendable ([String: String]) -> Void)
    /// Removes items the user chose one by one in the Storage section and confirmed, checked against
    /// `StorageRemovalPolicy` (wider than the cleaning method's `SafetyPolicy`). Replies with path → error for failures.
    func removeChosenItems(atPaths paths: [String], toTrash: Bool, reply: @escaping @Sendable ([String: String]) -> Void)
    /// `launchctl bootout system/<label>` (or `gui/<uid>/<label>` for an agent), then moves the job's plist to the client
    /// user's Trash or removes it, as `toTrash` says. Only a root-owned plist right in /Library/LaunchDaemons or
    /// /Library/LaunchAgents whose own `Label` is `label` (`SafetyPolicy.privilegedLaunchJobUnloadAllowed`).
    func unloadLaunchDaemon(label: String, plistPath: String, toTrash: Bool, reply: @escaping @Sendable (String?) -> Void)
    func version(reply: @escaping @Sendable (String) -> Void)
    /// Turns the built-in accelerometer's reports on or off (only root may). Off again when the client disconnects.
    func setMotionSensor(enabled: Bool, reply: @escaping @Sendable (Bool) -> Void)
    /// `tccutil reset <service> <bundleID>` as root, for decisions kept in the system TCC database. Only what
    /// `TCCResetPolicy` allows. Replies nil on success, otherwise the reason.
    func resetPrivacyPermission(service: String, bundleID: String, reply: @escaping @Sendable (String?) -> Void)
    /// Turns a third-party job in /Library/LaunchAgents (the client's `gui/<uid>` domain) or /Library/LaunchDaemons
    /// (`system`) on or off: `launchctl enable` + `bootstrap`, or `disable` + `bootout` (`LaunchJobPlan`). The plist is
    /// left as it is. Checked by `SafetyPolicy.privilegedLaunchJobToggleAllowed`. Replies nil on success.
    func setLaunchJob(label: String, plistPath: String, enabled: Bool, reply: @escaping @Sendable (String?) -> Void)
    /// The client's entries of the helper's Trash journal (`[TrashJournalEntry]` as JSON) that still describe an item
    /// in their Trash; stale entries are dropped from the journal. Nil when the journal cannot be used.
    func trashedItems(reply: @escaping @Sendable (Data?) -> Void)
    /// Puts the client's journal entry `itemID` back to its recorded path, with its recorded owners and modes
    /// (`TrashRestore`), when `TrashRestorePolicy` allows that path. `conflict` (a `TrashRestoreConflict` raw value) says
    /// what to do when the name is taken: skip, keep both («name 2»), or replace — what is there goes to the Trash first
    /// (recorded, restorable), never overwritten. `createFolders`: a missing original folder is made again, where the
    /// policy allows each folder. Replies nil on success, otherwise a `TrashRestoreFailure` raw value or the system's text.
    /// Since 1.8 (1.7 had `putBack(itemID:reply:)`).
    func putBack(itemID: String, conflict: String, createFolders: Bool, reply: @escaping @Sendable (String?) -> Void)
}

public enum HelperConstants {
    public static let appBundleID = "com.ovvi.MacWashing"
    public static let machServiceName = "com.ovvi.MacWashing.Helper"
    public static let daemonPlistName = "com.ovvi.MacWashing.Helper.plist"
    public static let version = "1.12"
    public static let teamID = "PWS2N8K4JX"

    /// The helper accepts connections only from our app signed by our team: in a Release build only a Developer ID
    /// signature without `get-task-allow` (a released app), in a Debug build also Apple Development (local builds).
    #if DEBUG
    public static let clientRequirement = developmentClientRequirement
    #else
    public static let clientRequirement = releaseClientRequirement
    #endif
    /// A released app: Developer ID Application of our team (the Developer ID CA and leaf marker OIDs), not debuggable.
    /// `Scripts/release/build-dmg.sh` reads this line and checks the signed app against it.
    public static let releaseClientRequirement =
        #"identifier "com.ovvi.MacWashing" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "PWS2N8K4JX" and !(entitlement["com.apple.security.get-task-allow"] exists)"#
    /// Any signature of our team, Apple Development included: Debug helpers only.
    public static let developmentClientRequirement =
        #"identifier "com.ovvi.MacWashing" and anchor apple generic and certificate leaf[subject.OU] = "PWS2N8K4JX""#
    /// The app talks only to a helper signed by our team.
    public static let helperRequirement =
        #"identifier "com.ovvi.MacWashing.Helper" and anchor apple generic and certificate leaf[subject.OU] = "PWS2N8K4JX""#
}

/// Who may use the helper. It runs as root for every user of the Mac, while macOS itself lets only administrators change
/// the system: everything but `version` is refused to a user outside the `admin` group (`HelperReply.adminRequired`).
public enum HelperAccess {
    /// True for root and for members of `admin` (`groups(of:)`, not only the primary group).
    public static func isAdministrator(uid: uid_t) -> Bool {
        if uid == 0 { return true }
        guard let group = getgrnam("admin") else { return false }
        return isMember(groups(of: uid), of: group.pointee.gr_gid)
    }

    /// Pure: `gid` is one of `groups`.
    public static func isMember(_ groups: [gid_t], of gid: gid_t) -> Bool {
        groups.contains(gid)
    }

    /// Every group of the user as Directory Services resolves it (`getgrouplist`: the primary group, supplementary and
    /// nested ones). Empty for an unknown user.
    public static func groups(of uid: uid_t) -> [gid_t] {
        guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else { return [] }
        let base = Int32(bitPattern: entry.pointee.pw_gid)
        var capacity: Int32 = 64
        while capacity <= 4096 {
            var list = [Int32](repeating: 0, count: Int(capacity))
            var count = capacity
            // -1: more groups than `count`; try again with room for them.
            if getgrouplist(name, base, &list, &count) == 0 {
                return list.prefix(Int(count)).map { gid_t(bitPattern: $0) }
            }
            capacity *= 4
        }
        return []
    }
}

/// Which paths may be removed. Shared by the app and the helper; the helper re-checks every request.
public enum SafetyPolicy {
    /// Roots where the helper may remove children. Removing a root itself is never allowed; the longest matching root
    /// decides. The set follows what app uninstallers leave: `/Library` folders and plug-ins, command-line tools in
    /// `/usr/local`, logs, temp files and package receipts.
    static let privilegedRoots = [
        "/Library/Caches", "/Library/Logs", "/Library/Application Support", "/Library/Preferences",
        "/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools",
        "/Library/Extensions", "/Library/Frameworks", "/Library/Internet Plug-Ins", "/Library/PreferencePanes",
        "/Library/QuickLook", "/Library/QuickTime", "/Library/Spotlight", "/Library/StartupItems", "/Library/Receipts",
        "/Library/Widgets", "/Library/Services", "/Library/Screen Savers", "/Library/ScriptingAdditions",
        "/Library/Input Methods", "/Library/Contextual Menu Items", "/Library/Components", "/Library/Filesystems",
        "/Library/PDF Services", "/Library/ColorPickers", "/Library/Address Book Plug-Ins",
        "/Library/Audio/Plug-Ins/VST", "/Library/Audio/Plug-Ins/VST3", "/Library/Audio/Plug-Ins/Components",
        "/Library/Audio/Plug-Ins/HAL", "/Library/Audio/Plug-Ins/MAS", "/Library/Audio/MIDI Drivers",
        // A vendor folder of its own (`/Library/Parallels`), never one of the standard folders.
        "/Library",
        "/Applications", "/Users/Shared", "/Users",
        "/usr/local/bin", "/usr/local/sbin", "/usr/local/lib", "/usr/local/libexec", "/usr/local/share",
        "/usr/local/include", "/usr/local/etc",
        // A vendor's folder right in /usr/local (`/usr/local/mysql-8.0.39-macos14-arm64` from MySQL's package), never one
        // of the standard folders (`usrLocalFolders`) or Homebrew's (`guardedNames`).
        "/usr/local",
        // Java runtimes their packages install (`temurin-21.jdk`); /Library/Java itself is macOS's.
        "/Library/Java/JavaVirtualMachines",
        "/private/var/log", "/private/var/tmp", "/private/tmp", "/private/var/db/receipts", "/private/var/folders",
        // A vendor's folder right in /opt (`/opt/salt`, `/opt/vagrant`), never a package manager's (`guardedNames`).
        "/opt",
        // What installers add to /etc (`/etc/paths.d/dotnet`, `/etc/salt`), never a file or folder macOS has there
        // (`guardedNames`).
        "/private/etc", "/private/etc/paths.d", "/private/etc/manpaths.d",
        // Printer drivers (`/Library/Printers/RWTS`) and their descriptions (`PPDs/Contents/Resources/<printer>.gz`).
        "/Library/Printers", "/Library/Printers/PPDs/Contents/Resources",
    ]
    /// Under these roots, `com.apple.*` children are always refused.
    static let appleGuardedRoots: Set<String> = Set(privilegedRoots).subtracting(["/Applications", "/Users", "/private/var/folders"])
    static let forbiddenPrefixes = [
        "/System", "/usr", "/bin", "/sbin", "/private/etc", "/private/var/db", "/private/var/run", "/Library/Apple",
        "/Library/Application Support/Apple", "/cores", "/dev",
    ]
    /// Parts of forbidden prefixes that third-party installers own.
    static let forbiddenExceptions = ["/usr/local", "/private/var/db/receipts", "/private/etc"]
    /// macOS's own trust, management and network settings and its staged system code in `/Library`: never removed by
    /// root under any policy (cleaning, Storage, putting back), whatever a root above them allows. Most sit in standard
    /// `/Library` folders the cleaning policy already refuses; `StorageRemovalPolicy` is wider, and
    /// `/Library/Preferences/SystemConfiguration` lies under a cleaning root. No exceptions: the user removes such
    /// things in System Settings, not file by file.
    static let systemDenied = [
        "/Library/Keychains", "/Library/Managed Preferences", "/Library/Preferences/SystemConfiguration",
        "/Library/Preferences/OpenDirectory", "/Library/Security", "/Library/SystemExtensions", "/Library/StagedExtensions",
        "/Library/StagedDriverExtensions", "/Library/KernelCollections", "/Library/Sandbox", "/Library/DirectoryServices",
        "/Library/OpenDirectory", "/Library/Updates", "/Library/SystemMigration", "/Library/CoreAnalytics",
        "/Library/OSAnalytics", "/Library/Trial",
    ]

    /// Standard folders of `/Library`: never removed themselves, and only the roots above are entered.
    public static let libraryFolders: Set<String> = [
        "Address Book Plug-Ins", "Apple", "Application Support", "Audio", "Automator", "Bluetooth", "Caches", "ColorPickers",
        "ColorSync", "Components", "Compositions", "Contextual Menu Items", "CoreAnalytics", "CoreMediaIO", "Desktop Pictures",
        "Developer", "Dictionaries", "DirectoryServices", "Documentation", "DriverExtensions", "Extensions", "Filesystems",
        "Fonts", "Frameworks", "GPUBundles", "Graphics", "Image Capture", "Input Methods", "Internet Plug-Ins", "Java",
        "KernelCollections", "Keyboard Layouts", "Keychains", "LaunchAgents", "LaunchDaemons", "Logs", "Mail",
        "Managed Preferences", "Messages", "Modem Scripts", "OSAnalytics", "OpenDirectory", "PDF Services", "Perl",
        "PreferencePanes", "Preferences", "Printers", "PrivilegedHelperTools", "QuickLook", "QuickTime", "Receipts",
        "Ruby", "Sandbox", "Screen Savers", "ScriptingAdditions", "Scripts", "Security", "Services", "Speech", "Spotlight",
        "StagedDriverExtensions", "StagedExtensions", "StartupItems", "SystemExtensions", "SystemMigration",
        "SystemProfiler", "Trial", "Updates", "User Pictures", "Video", "WebServer", "Widgets", "iTunes",
    ]
    /// Standard folders of `~/Library`: never removed themselves.
    static let userLibraryFolders: Set<String> = libraryFolders.union([
        "Accounts", "Application Scripts", "Assistant", "Assistants", "Autosave Information", "Biome", "Calendars",
        "CallServices", "CloudStorage", "Colors", "Containers", "Cookies", "CoreFollowUp", "DataAccess", "DataDeliveryServices",
        "DoNotDisturb", "DuetExpertCenter", "Favorites", "FeedbackLogs", "FileProvider", "Finance", "FontCollections",
        "FrontBoard", "GameKit", "Group Containers", "HTTPStorages", "HomeKit", "IdentityServices", "IntelligencePlatform",
        "Keyboard", "KeyboardServices", "LanguageModeling", "LockdownMode", "Maps", "Metadata", "Mobile Documents", "News",
        "Passes", "Personas", "Photos", "PrivateCloudCompute", "Reminders", "ResponseKit", "Safari", "SafariSafeBrowsing",
        "Saved Application State", "ScreenRecordings", "Sharing", "Shortcuts", "Sounds", "Spelling", "StatusKit",
        "Suggestions", "SyncedPreferences", "Translation", "UnifiedAssetFramework", "Weather", "WebKit",
    ])
    /// Shared folders of `/usr/local` (Homebrew and friends) and of `/private/var/log` and `/Users/Shared` that belong
    /// to macOS: never removed.
    static let guardedNames: [String: Set<String>] = [
        "/usr/local": ["man", "doc", "info", "locale", "zsh", "bash-completion", "fish", "aclocal", "pkgconfig", "cmake",
                       "Homebrew", "Cellar", "Caskroom", "Frameworks", "opt", "var"],
        "/private/var/log": ["asl", "DiagnosticMessages", "powermanagement", "install.log", "system.log", "wifi.log",
                             "fsck_apfs.log", "fsck_apfs_error.log", "fsck_hfs.log", "displaypolicy", "CoreDuet",
                             "shutdown_monitor.log", "daily.out", "weekly.out", "monthly.out", "apache2", "cups", "ppp",
                             "uucp", "mDNSResponder"],
        "/Users/Shared": ["SC Info", ".localized", "Relocated Items", "Previously Relocated Items", "adi"],
        // Homebrew's, MacPorts', Fink's and pkgsrc's prefixes, X11's.
        "/opt": ["homebrew", "local", "sw", "pkg", "X11"],
        // macOS's own files and folders of /etc (a clean macOS 26 and those of older ones), and `resolver`, which VPNs share.
        "/private/etc": [
            "afpovertcp.cfg", "aliases", "aliases.db", "apache2", "asl", "asl.conf", "auto_home", "auto_master", "auto_smb",
            "autofs.conf", "bashrc", "bashrc_Apple_Terminal", "bootpd.plist", "bootptab", "csh.cshrc", "csh.login",
            "csh.logout", "cups", "defaults", "dnsextd.conf", "emond.d", "exports", "find.codes", "fstab", "ftpusers",
            "gettytab", "group", "hosts", "hosts.equiv", "hosts.lpd", "irbrc", "kcpassword", "kern_loader.conf",
            "krb5.conf", "krb5.keytab", "launchd.conf", "localtime", "locate.rc", "mail.rc", "man.conf", "manpaths",
            "manpaths.d", "master.passwd", "nanorc", "networks", "newsyslog.conf", "newsyslog.d", "nfs.conf", "notify.conf",
            "nsmb.conf", "ntp-restrict.conf", "ntp.conf", "ntp_opendirectory.conf", "openldap", "pam.d", "passwd", "paths",
            "paths.d", "periodic", "pf.anchors", "pf.conf", "pf.os", "php-fpm.conf.default", "php-fpm.d", "php.ini.default",
            "postfix", "ppp", "printcap", "profile", "protocols", "racoon", "rc.common", "rc.local", "rc.netboot",
            "resolv.conf", "resolver", "rmtab", "rpc", "rtadvd.conf", "security", "services", "shells", "smb.conf", "snmp",
            "ssh", "ssl", "sudo_lecture", "sudoers", "sudoers.d", "synthetic.conf", "synthetic.d", "syslog.conf", "ttys",
            "uucp", "wfs", "xtab", "zprofile", "zshenv", "zshrc", "zshrc_Apple_Terminal",
        ],
        // macOS's own (`10-cryptex`, `100-rvictl`) and Homebrew's.
        "/private/etc/paths.d": ["10-cryptex", "100-rvictl", "homebrew"],
        "/private/etc/manpaths.d": ["homebrew"],
        // Their own folders: printers' icons and descriptions.
        "/Library/Printers": ["Icons", "PPDs"],
    ]
    /// macOS's own settings in `~/Library/Preferences` (folded file names without `.plist`): keyboard shortcuts, input
    /// sources, the Dock, Finder, Spotlight, accessibility. A rule that marks one as junk is a mistake in the database;
    /// removing one while the session runs leaves the system acting on a state it no longer has.
    static let systemPreferences = Set([
        ".globalpreferences", "com.apple.symbolichotkeys", "com.apple.hitoolbox", "com.apple.inputsources",
        "com.apple.textinputmenu", "com.apple.textinputmenuagent", "com.apple.characterpicker", "com.apple.keyboardservicesd",
        "com.apple.keyboard", "com.apple.keyboardtype", "com.apple.inputmethodkit", "com.apple.universalaccess",
        "com.apple.spotlight", "com.apple.spotlightui", "com.apple.dock", "com.apple.finder", "com.apple.systemuiserver",
        "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.loginwindow", "com.apple.loginitems",
        "com.apple.screensaver", "com.apple.menuextra.clock", "com.apple.windowmanager", "com.apple.assistant.support",
        "com.apple.siri", "com.apple.speech.recognition.applespeechserver", "com.apple.applemultitouchtrackpad",
        "com.apple.driver.appleBluetoothMultitouch.trackpad", "com.apple.driver.appleBluetoothMultitouch.mouse",
        "com.apple.AppleMultitouchMouse", "com.apple.security", "com.apple.LaunchServices", "pbs",
    ].map(folded))

    /// True for a file of `systemPreferences` (with any suffix: `.plist`, `.plist.lockfile`, `.<UUID>.plist`) and for
    /// anything in `Preferences/ByHost`. `rest` is the path under the home, folded.
    static func isSystemPreference(_ rest: [String]) -> Bool {
        guard rest.count >= 3, rest[0] == "library", rest[1] == "preferences" else { return false }
        if rest[2] == "byhost" { return true }
        guard rest.count == 3 else { return false }
        let name = rest[2]
        return systemPreferences.contains { name == $0 || name.hasPrefix($0 + ".") }
    }

    /// The standard folders of /usr/local: shared by every installer, never removed themselves.
    static let usrLocalFolders: Set<String> = ["bin", "sbin", "lib", "libexec", "share", "include", "etc", "man", "src", "lib64",
                                               "remotedesktop"]

    /// Folders of /Applications that are never removed as a whole (apps inside them still may be).
    static let applicationsFolders: Set<String> = ["Utilities"]

    // The lists above, folded once (`folded`): every guard compares folded names, as the startup disk compares them.
    static let foldedRoots: [(original: String, folded: String)] = privilegedRoots.map { ($0, folded($0)) }
    static let foldedAppleGuardedRoots = Set(appleGuardedRoots.map(folded))
    static let foldedForbiddenPrefixes = forbiddenPrefixes.map(folded)
    static let foldedForbiddenExceptions = forbiddenExceptions.map(folded)
    static let foldedSystemDenied = systemDenied.map(folded)
    static let foldedLibraryFolders = Set(libraryFolders.map(folded))
    static let foldedUserLibraryFolders = Set(userLibraryFolders.map(folded))
    static let foldedGuardedNames = guardedNames.mapValues { Set($0.map(folded)) }
    static let foldedApplicationsFolders = Set(applicationsFolders.map(folded))
    static let foldedUsrLocalFolders = Set(usrLocalFolders.map(folded))

    /// A name or path as the startup disk compares it: case-insensitively, with canonically equivalent Unicode forms
    /// (NFC and NFD) equal. `/Library/caches` is `/Library/Caches` on a case-insensitive APFS volume, so every guard
    /// compares folded names: a "wrongly" cased or decomposed request must not slip past the standard folders.
    public static func folded(_ text: some StringProtocol) -> String {
        String(text).precomposedStringWithCanonicalMapping.lowercased().precomposedStringWithCanonicalMapping
    }

    /// A clean absolute path: no `.`/`..` components, no empty components.
    public static func isNormalized(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count > 1, !path.hasSuffix("/") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Checks a path the helper is asked to remove. `resolvedParent` is the parent after resolving symlinks;
    /// `clientHome` is the home of the user who asked (paths under /Users are allowed only inside it, and only when the
    /// path as asked is there too: a link elsewhere that resolves into the home does not count); `clientUID` is that
    /// user (in `/private/var/folders` only their own tree).
    ///
    /// Roots and guarded names compare folded (`folded`). The client's home compares exactly (up to Unicode
    /// normalization): on a case-sensitive disk `/Users/Bob` and `/Users/bob` are two people.
    public static func privilegedRemovalAllowed(_ path: String, resolvedParent: String, clientHome: String? = nil,
                                                clientUID: uid_t = getuid()) -> Bool {
        guard isNormalized(path), isNormalized(resolvedParent) || resolvedParent == "/" else { return false }
        let name = String(path.split(separator: "/").last ?? "")
        let resolved = resolvedParent == "/" ? "/" + name : resolvedParent + "/" + name
        let home = clientHome.map(normalizedHome)
        for candidate in [path, resolved] {
            if isForbidden(candidate) || isSystemDenied(candidate) { return false }
            let key = folded(candidate)
            guard let root = foldedRoots.filter({ key.hasPrefix($0.folded + "/") }).max(by: { $0.folded.count < $1.folded.count })
            else { return false }
            let rest = key.dropFirst(root.folded.count + 1).split(separator: "/").map(String.init)
            guard let first = rest.first else { return false }
            if foldedAppleGuardedRoots.contains(root.folded), first.hasPrefix("com.apple.") { return false }
            let guardKey = root.original.hasPrefix("/usr/local/") ? "/usr/local" : root.original
            if foldedGuardedNames[guardKey]?.contains(first) == true { return false }
            switch root.original {
            case "/Applications":
                guard applicationsItemAllowed(rest) else { return false }
            case "/Library":
                guard !foldedLibraryFolders.contains(first), !first.hasPrefix(".") else { return false }
            case "/usr/local":
                guard !foldedUsrLocalFolders.contains(first), !first.hasPrefix(".") else { return false }
            case "/Users":
                guard let home, isNormalized(home), isInsideHome(candidate, home), isInsideHome(path, home),
                      userRemovalAllowed(candidate, home: home) else { return false }
            case "/private/var/folders":
                // `/private/var/folders/<xx>/<user's folder>/{C,T,0}/…`: only the asking user's own tree.
                if rest.count < 4 { return false }
                guard temporaryTreeOwner(candidate) == clientUID else { return false }
            default:
                break
            }
        }
        return true
    }

    /// Strictly inside `home`, compared exactly up to Unicode normalization.
    static func isInsideHome(_ path: String, _ home: String) -> Bool {
        path.precomposedStringWithCanonicalMapping.hasPrefix(home.precomposedStringWithCanonicalMapping + "/")
    }

    /// One of `systemDenied` or inside one, compared folded.
    public static func isSystemDenied(_ path: String) -> Bool {
        let key = folded(path)
        return foldedSystemDenied.contains { key == $0 || key.hasPrefix($0 + "/") }
    }

    /// The owner of the per-user tree `/private/var/folders/<xx>/<yy>` that `path` lies in: a real folder (not a link),
    /// read from disk. Nil when it is not there.
    static func temporaryTreeOwner(_ path: String) -> uid_t? {
        let parts = path.split(separator: "/")
        guard parts.count >= 5 else { return nil }
        let tree = "/" + parts.prefix(5).joined(separator: "/")
        var info = stat()
        guard lstat(tree, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return info.st_uid
    }

    /// True when the folder a request names (`path` without its last part) differs from what it resolves to
    /// (`resolvedParent`, its `realpath`), that is when some folder on the way is a symbolic link: the helper refuses
    /// such a request. A link planted in a folder anyone may write to (`/Library/Caches`, `/Users/Shared`) would
    /// otherwise turn a scanned path into one in another place, someone's home included. Names compare folded, so the
    /// on-disk spelling of a folder is not taken for a link.
    public static func parentHasLink(_ path: String, resolvedParent: String) -> Bool {
        guard isNormalized(path) else { return true }
        let parent = (path as NSString).deletingLastPathComponent
        return folded(parent) != folded(resolvedParent)
    }

    /// Under a forbidden prefix (macOS itself), compared folded.
    static func isForbidden(_ path: String) -> Bool {
        let key = folded(path)
        func under(_ prefix: String) -> Bool { key == prefix || key.hasPrefix(prefix + "/") }
        return foldedForbiddenPrefixes.contains(where: under) && !foldedForbiddenExceptions.contains(where: under)
    }

    /// In /Applications: an app bundle (not one inside another bundle), or a vendor folder right in /Applications — never
    /// something inside such a folder (`/Applications/MAMP/htdocs`) or inside a bundle. Names compare folded.
    static func applicationsItemAllowed<S: StringProtocol>(_ rest: [S]) -> Bool {
        let rest = rest.map { folded($0) }
        guard let first = rest.first, let last = rest.last else { return false }
        if last.hasSuffix(".app") { return !rest.dropLast().contains(where: { $0.hasSuffix(".app") }) }
        return rest.count == 1 && !first.hasPrefix(".") && !foldedApplicationsFolders.contains(first)
    }

    /// Checks a path the app removes itself (inside the user's home or on an external volume). Folder names compare
    /// folded (`folded`); the home itself compares exactly, up to Unicode normalization.
    public static func userRemovalAllowed(_ path: String, home: String) -> Bool {
        guard isNormalized(path) else { return false }
        let homePath = normalizedHome(home).precomposedStringWithCanonicalMapping
        let path = path.precomposedStringWithCanonicalMapping
        let key = folded(path)
        if key.hasPrefix("/volumes/") {
            let parts = path.split(separator: "/")
            guard parts.count >= 3 else { return false }
            // `/Volumes/Macintosh HD` is a link to the startup disk: it is not an external volume.
            return !resolvesToStartupDisk("/Volumes/" + parts[1])
        }
        if key.hasPrefix("/applications/") {
            return applicationsItemAllowed(Array(key.split(separator: "/").dropFirst()))
        }
        guard path.hasPrefix(homePath + "/") else { return false }
        let rest = path.dropFirst(homePath.count + 1).split(separator: "/").map(folded)
        guard let first = rest.first else { return false }
        if isSystemPreference(rest) { return false }
        // Top-level home folders (Documents, Library…) and the standard Library folders are never removed; a vendor
        // folder right in Library (`~/Library/Parallels`) may be.
        if rest.count == 1 && !first.hasPrefix(".") && !first.contains(".") { return false }
        if first == "library" {
            guard rest.count >= 2 else { return false }
            if rest.count == 2 {
                let folder = rest[1]
                return !foldedUserLibraryFolders.contains(folder) && !folder.hasPrefix(".") && !folder.hasPrefix("com.apple.")
            }
        }
        return true
    }

    static func normalizedHome(_ home: String) -> String {
        home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
    }

    /// True when a /Volumes entry is really the startup disk.
    static func resolvesToStartupDisk(_ volume: String) -> Bool {
        guard let pointer = realpath(volume, nil) else { return false }
        defer { free(pointer) }
        return String(cString: pointer) == "/"
    }
}
