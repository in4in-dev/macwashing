import Darwin
import Foundation
import MacWashingXPC
import Security
import Testing
@testable import MacWashingKit

/// Hardening of the helper: links on the way, administrators only, macOS's own settings, other users' temporary
/// trees, other volumes, and which builds the helper talks to.
@Suite("Helper: links, administrators, system deny list")
struct HelperHardeningTests {
    static let home = "/Users/a"

    private func privileged(_ path: String, parent: String? = nil, uid: uid_t = getuid()) -> Bool {
        SafetyPolicy.privilegedRemovalAllowed(path, resolvedParent: parent ?? (path as NSString).deletingLastPathComponent,
                                              clientHome: Self.home, clientUID: uid)
    }

    private static func resolved(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    @Test(arguments: [
        "/Library/Keychains/System.keychain", "/Library/keychains/system.keychain", "/Library/Managed Preferences/a/x.plist",
        "/Library/Preferences/SystemConfiguration/preferences.plist", "/Library/preferences/systemconfiguration/x",
        "/Library/Preferences/SystemConfiguration", "/Library/Preferences/OpenDirectory/x",
        "/Library/Security/SecurityAgentPlugins/x.bundle", "/LIBRARY/SECURITY/x", "/Library/SystemExtensions/x",
        "/Library/StagedExtensions/Library/Extensions/x.kext", "/Library/KernelCollections/x", "/Library/Updates/x",
    ])
    func theDenyListHoldsUnderEveryPolicy(_ path: String) {
        let parent = (path as NSString).deletingLastPathComponent
        #expect(SafetyPolicy.isSystemDenied(path), "\(path)")
        #expect(!privileged(path), "\(path)")
        #expect(StorageRemovalPolicy.route(for: path, resolvedParent: parent, home: Self.home) == nil, "\(path)")
        #expect(!TrashRestorePolicy.destinationAllowed(path, resolvedParent: parent, home: Self.home, protectedPaths: []), "\(path)")
    }

    @Test func legitimateSystemPathsStayAllowed() {
        for path in ["/Library/Preferences/com.vendor.app.plist", "/Library/Caches/org.vendor", "/Library/Application Support/Vendor",
                     "/Library/LaunchDaemons/com.vendor.helper.plist", "/Library/Parallels"] {
            #expect(privileged(path), "\(path)")
            #expect(!SafetyPolicy.isSystemDenied(path), "\(path)")
        }
        // Names that only start like a denied folder.
        #expect(!SafetyPolicy.isSystemDenied("/Library/Securityd"))
        #expect(!SafetyPolicy.isSystemDenied("/Library/Preferences/SystemConfigurationTool.plist"))
        #expect(StorageRemovalPolicy.route(for: "/Library/Fonts/Vendor.ttf", resolvedParent: "/Library/Fonts", home: Self.home)
            == .privileged)
    }

    /// A link in a folder anyone may write to that resolves into the client's home is not the client's home.
    @Test func aPathResolvedIntoTheHomeFromElsewhereIsRefused() {
        #expect(!privileged("/Library/Caches/evil/Thesis", parent: "/Users/a/Documents"))
        #expect(!privileged("/Users/Shared/evil/Thesis", parent: "/Users/a/Documents"))
        #expect(!privileged("/private/tmp/evil/x", parent: "/Users/a/Library/Caches"))
        // The plain path in the home is still the cleaning policy's to judge.
        #expect(privileged("/Users/a/Library/Caches/com.vendor.app"))
    }

    @Test func aLinkInTheParentIsSeen() throws {
        let base = try #require(Self.resolved(FileManager.default.temporaryDirectory.fsPath))
        let folder = base + "/mw-link-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder + "/real", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try FileManager.default.createSymbolicLink(atPath: folder + "/link", withDestinationPath: folder + "/real")
        let linked = try #require(Self.resolved(folder + "/link"))
        let real = try #require(Self.resolved(folder + "/real"))
        #expect(SafetyPolicy.parentHasLink(folder + "/link/item", resolvedParent: linked))
        #expect(!SafetyPolicy.parentHasLink(folder + "/real/item", resolvedParent: real))
        // The item itself may be a link: it is removed, not followed.
        #expect(!SafetyPolicy.parentHasLink(folder + "/link", resolvedParent: try #require(Self.resolved(folder))))
        // A folder written in another case than on disk is not a link.
        #expect(!SafetyPolicy.parentHasLink(folder + "/REAL/item", resolvedParent: real))
        // `/var` is a link to `/private/var`: such a request names a link too.
        #expect(SafetyPolicy.parentHasLink("/var/log/x.log", resolvedParent: "/private/var/log"))
        #expect(SafetyPolicy.parentHasLink("relative/x", resolvedParent: "/relative"))
    }

    /// `/private/var/folders/<xx>/<yy>` belongs to one user: another user's tree is not theirs to clean.
    @Test func onlyTheClientsOwnTemporaryTree() throws {
        let temporary = try #require(Self.resolved(FileManager.default.temporaryDirectory.fsPath))
        try #require(temporary.hasPrefix("/private/var/folders/"))
        let item = temporary + "/com.vendor.cache"
        #expect(privileged(item, uid: getuid()))
        #expect(!privileged(item, uid: getuid() + 1))
        #expect(!privileged("/private/var/folders/zz/no-such-tree/T/x", uid: getuid()))
        #expect(StorageRemovalPolicy.route(for: item, resolvedParent: temporary, home: Self.home, clientUID: getuid()) != nil)
        #expect(StorageRemovalPolicy.route(for: item, resolvedParent: temporary, home: Self.home, clientUID: getuid() + 1) == nil)
    }

    /// The Storage section removes on another volume as the user; root never does.
    @Test func theHelperNeverRemovesOnAnotherVolume() {
        let path = "/Volumes/Backup/Photos", parent = "/Volumes/Backup"
        #expect(StorageRemovalPolicy.route(for: path, resolvedParent: parent, home: Self.home) == .user)
        #expect(!StorageRemovalPolicy.privilegedAllowed(path, resolvedParent: parent, home: Self.home))
        #expect(!StorageRemovalPolicy.privilegedAllowed("/opt/x", resolvedParent: "/Volumes/Backup", home: Self.home))
        #expect(StorageRemovalPolicy.privilegedAllowed("/opt/homebrew", resolvedParent: "/opt", home: Self.home))
    }

    @Test func onlyAdministratorsUseTheHelper() throws {
        #expect(HelperAccess.isMember([20, 12, 80], of: 80))
        #expect(!HelperAccess.isMember([20, 12], of: 80))
        #expect(HelperAccess.isAdministrator(uid: 0))
        #expect(!HelperAccess.isAdministrator(uid: uid_t(bitPattern: -2)), "nobody")
        #expect(!HelperAccess.isAdministrator(uid: 1), "daemon")
        #expect(!HelperAccess.isAdministrator(uid: 4_242_424), "an unknown user")
        let me = getuid()
        let primary = try #require(getpwuid(me)).pointee.pw_gid
        #expect(HelperAccess.groups(of: me).contains(primary))
        let admin = try #require(getgrnam("admin")).pointee.gr_gid
        #expect(HelperAccess.isAdministrator(uid: me) == HelperAccess.groups(of: me).contains(admin))
        #expect(HelperReply.adminRequired != HelperReply.gone && HelperReply.adminRequired != HelperReply.notAllowed)
    }

    /// A Release helper accepts only a released app; a Debug one also a development build.
    @Test func theReleaseRequirementIsDeveloperIDOnly() {
        let release = HelperConstants.releaseClientRequirement
        #expect(release.contains("certificate leaf[field.1.2.840.113635.100.6.1.13] exists"))
        #expect(release.contains(#"!(entitlement["com.apple.security.get-task-allow"] exists)"#))
        #expect(release.contains(#"certificate leaf[subject.OU] = "\#(HelperConstants.teamID)""#))
        #expect(!HelperConstants.developmentClientRequirement.contains("6.1.13"))
        #if DEBUG
        #expect(HelperConstants.clientRequirement == HelperConstants.developmentClientRequirement)
        #else
        #expect(HelperConstants.clientRequirement == release)
        #endif
        var requirement: SecRequirement?
        #expect(SecRequirementCreateWithString(release as CFString, [], &requirement) == errSecSuccess)
    }
}
