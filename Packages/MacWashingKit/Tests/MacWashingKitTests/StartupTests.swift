import Foundation
import MacWashingXPC
import Testing
@testable import MacWashingKit

/// The Startup section against a fake Mac and a simulated launchd: the real launchctl is never run.
@Suite("Startup")
struct StartupTests {
    static let uid: uid_t = 501

    /// Two apps, user agents (one of an installed app, one broken, one Apple, one disabled in its plist, one owned through
    /// `AssociatedBundleIdentifiers`), a system agent and daemon, and an app with an embedded login item and agent.
    private func makeMac() throws -> FakeMac {
        let mac = try FakeMac()
        try mac.app("Dropbox", bundleID: "com.dropbox.app")
        try mac.app("Sync", bundleID: "com.example.sync")
        try mac.file("bin/ls", in: mac.root)
        try mac.file("System/Library/CoreServices/tool", in: mac.root)
        try mac.plist("Library/LaunchAgents/com.dropbox.updater.plist", [
            "Label": "com.dropbox.updater", "RunAtLoad": true, "StartInterval": 3600,
            "ProgramArguments": ["~/Applications/Dropbox.app/Contents/MacOS/Dropbox", "--update"],
        ])
        try mac.plist("Library/LaunchAgents/org.dead.agent.plist", [
            "Label": "org.dead.agent", "Program": "/Applications/Gone.app/Contents/MacOS/agent", "KeepAlive": ["SuccessfulExit": false],
        ])
        try mac.plist("Library/LaunchAgents/com.apple.thing.plist", ["Label": "com.apple.thing", "Program": "/bin/ls"])
        try mac.plist("Library/LaunchAgents/net.quiet.agent.plist", ["Label": "net.quiet.agent", "Program": "/bin/ls", "Disabled": true])
        try mac.plist("Library/LaunchAgents/net.helper.login.plist", [
            "Label": "net.helper.login", "Program": "/bin/ls", "AssociatedBundleIdentifiers": ["com.example.sync"],
        ])
        // A third-party label that runs a part of macOS: never switched from here.
        try mac.plist("Library/LaunchAgents/net.other.label.plist", ["Label": "net.other.label", "Program": "/System/Library/CoreServices/tool"])
        try mac.file("usr/local/bin/vendord", in: mac.root)
        try mac.plist("Library/LaunchAgents/com.vendor.agent.plist", ["Label": "com.vendor.agent", "Program": "/usr/local/bin/vendord"], in: mac.root)
        try mac.plist("Library/LaunchDaemons/com.vendor.daemon.plist", [
            "Label": "com.vendor.daemon", "Program": "/usr/local/bin/vendord", "RunAtLoad": true, "KeepAlive": true,
        ], in: mac.root)
        try mac.plist("Library/LaunchDaemons/com.apple.ftpd.plist", ["Label": "com.apple.ftpd", "Program": "/usr/libexec/ftpd"], in: mac.root)
        // Sync carries a login item helper app and an SMAppService agent.
        let sync = mac.home.appending(path: "Applications/Sync.app")
        try mac.app("SyncHelper", bundleID: "com.example.sync.helper", in: sync.appending(path: "Contents/Library/LoginItems"))
        try mac.plist("Contents/Library/LaunchAgents/com.example.sync.agent.plist", [
            "Label": "com.example.sync.agent", "BundleProgram": "Contents/MacOS/Sync",
        ], in: sync)
        return mac
    }

    private func scan(_ mac: FakeMac, launchd: SimulatedLaunchctl) async -> [StartupItem] {
        await StartupScanner(env: mac.environment(), launchctl: launchd, uid: Self.uid).scan()
    }

    private func item(_ items: [StartupItem], _ label: String) -> StartupItem? {
        items.first { $0.label == label }
    }

    // MARK: launchd's switches

    @Test func parsesPrintDisabled() {
        let output = """
            \tdisabled services = {
            \t\t"com.example.PhotoStudio4.Menu" => enabled
            \t\t"com.adobe.GC.AGM" => disabled
            \t\t"homebrew.mxcl.postgresql@14" => enabled
            \t\t"org.old.style" => true
            \t\t"org.old.other" => false
            \t}
            \tdisabled login items = {
            \t\t"com.login.item" => disabled
            \t}
            """
        #expect(LaunchdOverrides.parse(output) == [
            "com.example.PhotoStudio4.Menu": false, "com.adobe.GC.AGM": true, "homebrew.mxcl.postgresql@14": false,
            "org.old.style": true, "org.old.other": false,
        ])
        #expect(LaunchdOverrides.parse("").isEmpty)
    }

    @Test func theRealLaunchctlIsReadOnlyUnlessAsked() {
        let reading = SystemLaunchctl()
        #expect(reading.allows(["print-disabled", "gui/501"]))
        #expect(reading.allows(["print", "system/com.vendor.daemon"]))
        for verb in ["disable", "enable", "bootout", "bootstrap", "load", "unload", "remove", "kill"] {
            #expect(!reading.allows([verb, "gui/501/com.vendor.agent"]))
        }
        let changing = SystemLaunchctl(allowsChanges: true)
        for verb in ["disable", "enable", "bootout", "bootstrap"] { #expect(changing.allows([verb, "x"])) }
        for verb in ["load", "unload", "remove", "kill", "submit", "reboot"] { #expect(!changing.allows([verb, "x"])) }
        #expect(!changing.allows([]))
    }

    // MARK: Scanning

    @Test func findsThirdPartyJobsGroupedByKind() async throws {
        let mac = try makeMac()
        let items = await scan(mac, launchd: SimulatedLaunchctl())
        let labels = Set(items.compactMap(\.label))
        #expect(!labels.contains("com.apple.thing"))
        #expect(!labels.contains("com.apple.ftpd"))
        #expect(item(items, "com.dropbox.updater")?.kind == .userAgent)
        #expect(item(items, "com.vendor.agent")?.kind == .systemAgent)
        #expect(item(items, "com.vendor.daemon")?.kind == .systemDaemon)
        #expect(item(items, "com.example.sync.helper")?.kind == .loginItem)
        #expect(item(items, "com.example.sync.agent")?.kind == .loginItem)
        #expect(StartupGroup.make(items).map(\.kind) == [.loginItem, .userAgent, .systemAgent, .systemDaemon])
    }

    @Test func readsWhatStartsTheJob() async throws {
        let mac = try makeMac()
        let items = await scan(mac, launchd: SimulatedLaunchctl())
        let dropbox = try #require(item(items, "com.dropbox.updater"))
        #expect(dropbox.runAtLoad)
        #expect(dropbox.startInterval == 3600)
        #expect(!dropbox.keepAlive)
        #expect(dropbox.name == "Dropbox")
        #expect(item(items, "org.dead.agent")?.keepAlive == true)
        let daemon = try #require(item(items, "com.vendor.daemon"))
        #expect(daemon.keepAlive && daemon.runAtLoad)
        #expect(daemon.name == "com.vendor.daemon")
    }

    @Test func resolvesOwners() async throws {
        let mac = try makeMac()
        let items = await scan(mac, launchd: SimulatedLaunchctl())
        // The program inside an installed app.
        #expect(item(items, "com.dropbox.updater")?.owner?.name == "Dropbox")
        // AssociatedBundleIdentifiers wins over a label that says nothing.
        #expect(item(items, "net.helper.login")?.owner?.bundleID == "com.example.sync")
        // Embedded items belong to the app that carries them.
        #expect(item(items, "com.example.sync.helper")?.owner?.name == "Sync")
        #expect(item(items, "com.example.sync.agent")?.program?.hasSuffix("Sync.app/Contents/MacOS/Sync") == true)
    }

    @Test func marksJobsWhoseProgramIsGone() async throws {
        let mac = try makeMac()
        let items = await scan(mac, launchd: SimulatedLaunchctl())
        #expect(item(items, "org.dead.agent")?.isBroken == true)
        #expect(item(items, "com.dropbox.updater")?.isBroken == false)
        #expect(item(items, "com.vendor.daemon")?.isBroken == false)
        // The same judgement as the junk scan's broken login items.
        let junk = await BrokenLoginItemsScanner().scan(mac.environment())
        #expect(junk.entries.map(\.title) == ["org.dead.agent"])
        #expect(StartupGroup.make(items, filter: .broken).flatMap(\.items).compactMap(\.label) == ["org.dead.agent"])
    }

    @Test func readsLaunchdStateAndChangesNothing() async throws {
        let mac = try makeMac()
        let launchd = SimulatedLaunchctl(
            overrides: ["gui/501": ["com.dropbox.updater": true, "net.quiet.agent": false], "system": ["com.vendor.daemon": true]],
            loaded: ["gui/501/net.helper.login", "system/com.vendor.daemon", "gui/501/com.example.sync.agent"]
        )
        let items = await scan(mac, launchd: launchd)
        // launchd's switch wins over the plist's Disabled key, both ways.
        #expect(item(items, "com.dropbox.updater")?.isEnabled == false)
        #expect(item(items, "net.quiet.agent")?.isEnabled == true)
        #expect(item(items, "net.helper.login")?.isEnabled == true)
        #expect(item(items, "net.helper.login")?.isLoaded == true)
        #expect(item(items, "com.dropbox.updater")?.isLoaded == false)
        #expect(item(items, "com.vendor.daemon")?.isEnabled == false)
        #expect(item(items, "com.vendor.daemon")?.isLoaded == true)
        // What an app registered: on while loaded.
        #expect(item(items, "com.example.sync.agent")?.isEnabled == true)
        #expect(item(items, "com.example.sync.helper")?.isEnabled == false)

        let calls = await launchd.calls
        #expect(calls.contains(["print-disabled", "gui/501"]))
        #expect(calls.contains(["print-disabled", "system"]))
        #expect(calls.contains(["print", "system/com.vendor.daemon"]))
        #expect(calls.allSatisfy { SystemLaunchctl.readOnlyVerbs.contains($0[0]) })
    }

    @Test func tellsWhatCanBeSwitchedAndWhatNeedsAnAdmin() async throws {
        let mac = try makeMac()
        let items = await scan(mac, launchd: SimulatedLaunchctl())
        #expect(item(items, "com.dropbox.updater")?.canToggle == true)
        #expect(item(items, "com.dropbox.updater")?.needsAdmin == false)
        #expect(item(items, "com.vendor.daemon")?.canToggle == true)
        #expect(item(items, "com.vendor.daemon")?.needsAdmin == true)
        #expect(item(items, "com.vendor.agent")?.needsAdmin == true)
        // A program in /System.
        #expect(item(items, "net.other.label")?.toggleBlock == .protected)
        // Registered by apps: System Settings only.
        #expect(item(items, "com.example.sync.helper")?.toggleBlock == .systemSettings)
        #expect(item(items, "com.example.sync.agent")?.canToggle == false)
    }

    @Test func aDaemonOnlyRootCanReadIsLeftToTheHelper() async throws {
        let mac = try makeMac()
        try mac.plist("Library/LaunchDaemons/com.vpn.helper.plist", ["Label": "com.vpn.helper", "Program": "/usr/local/bin/vendord"], in: mac.root)
        let path = mac.root.appending(path: "Library/LaunchDaemons/com.vpn.helper.plist").fsPath
        chmod(path, 0)
        defer { chmod(path, 0o644) }
        let items = await scan(mac, launchd: SimulatedLaunchctl())
        let vpn = try #require(item(items, "com.vpn.helper"))
        #expect(vpn.canToggle)
        #expect(vpn.kind == .systemDaemon)
    }

    @Test func homebrewServicesBelongToHomebrew() async throws {
        let mac = try makeMac()
        try mac.plist("Library/LaunchAgents/homebrew.mxcl.postgresql@14.plist", [
            "Label": "homebrew.mxcl.postgresql@14", "ProgramArguments": ["/bin/ls", "-D", "/opt/homebrew/var/postgresql@14"],
        ])
        let items = await scan(mac, launchd: SimulatedLaunchctl())
        let postgres = try #require(item(items, "homebrew.mxcl.postgresql@14"))
        #expect(postgres.owner?.name == "Homebrew")
        #expect(postgres.canToggle)
    }

    @Test func legacyLoginItemsAreListedReadOnly() async throws {
        let mac = try makeMac()
        let sync = mac.home.appending(path: "Applications/Sync.app")
        let items = await StartupScanner(env: mac.environment(), launchctl: SimulatedLaunchctl(), uid: Self.uid, legacyLoginItems: [sync]).scan()
        let legacy = try #require(items.first { $0.source == .legacyLoginItem })
        #expect(legacy.name == "Sync")
        #expect(legacy.isEnabled)
        #expect(!legacy.canToggle)
    }

    // MARK: Filter and search

    @Test func filtersAndSearches() async throws {
        let mac = try makeMac()
        let launchd = SimulatedLaunchctl(overrides: ["gui/501": ["com.dropbox.updater": true]])
        let items = await scan(mac, launchd: launchd)
        let off = StartupGroup.make(items, filter: .off).flatMap(\.items).compactMap(\.label)
        #expect(off.contains("com.dropbox.updater"))
        #expect(!off.contains("com.vendor.daemon"))
        #expect(!StartupGroup.make(items, filter: .on).flatMap(\.items).contains { $0.label == "com.dropbox.updater" })
        #expect(StartupGroup.make(items, query: "dropbox").flatMap(\.items).compactMap(\.label) == ["com.dropbox.updater"])
        #expect(StartupGroup.make(items, query: "SYNC").flatMap(\.items).count == 3)
        #expect(StartupGroup.make(items, query: "nothing like this").isEmpty)
        // Broken first in its group.
        #expect(StartupGroup.make(items).first { $0.kind == .userAgent }?.items.first?.label == "org.dead.agent")
    }

    // MARK: Switching

    private func toggler(_ mac: FakeMac, launchd: SimulatedLaunchctl, privileged: (any LaunchJobSwitching)? = nil) -> StartupToggler {
        StartupToggler(home: mac.home, systemRoot: mac.root, uid: Self.uid, launchctl: launchd, privileged: privileged)
    }

    @Test func turnsAUserAgentOffAndOnWithoutTouchingItsFile() async throws {
        let mac = try makeMac()
        let launchd = SimulatedLaunchctl(loaded: ["gui/501/com.dropbox.updater"])
        let agent = try #require(item(await scan(mac, launchd: launchd), "com.dropbox.updater"))
        let before = try Data(contentsOf: agent.url)

        #expect(await toggler(mac, launchd: launchd).setEnabled(false, agent) == .done)
        #expect(await launchd.overrides["gui/501"]?["com.dropbox.updater"] == true)
        #expect(await launchd.loaded.isEmpty)
        #expect(item(await StartupScanner(env: mac.environment(), launchctl: launchd, uid: Self.uid).withState([agent]), "com.dropbox.updater")?.isEnabled == false)

        #expect(await toggler(mac, launchd: launchd).setEnabled(true, agent) == .done)
        #expect(await launchd.overrides["gui/501"]?["com.dropbox.updater"] == false)
        #expect(await launchd.loaded == ["gui/501/com.dropbox.updater"])

        let changing = await launchd.calls.filter { LaunchJobPlan.changingVerbs.contains($0[0]) }
        #expect(changing == [
            ["disable", "gui/501/com.dropbox.updater"], ["bootout", "gui/501/com.dropbox.updater"],
            ["enable", "gui/501/com.dropbox.updater"], ["bootstrap", "gui/501", agent.url.fsPath],
        ])
        #expect(try Data(contentsOf: agent.url) == before)
    }

    @Test func turningOffAJobThatIsNotLoadedWorks() async throws {
        let mac = try makeMac()
        let launchd = SimulatedLaunchctl()
        let agent = try #require(item(await scan(mac, launchd: launchd), "net.helper.login"))
        #expect(await toggler(mac, launchd: launchd).setEnabled(false, agent) == .done)
        #expect(await launchd.overrides["gui/501"]?["net.helper.login"] == true)
    }

    @Test func systemJobsGoThroughTheHelper() async throws {
        let mac = try makeMac()
        let launchd = SimulatedLaunchctl(loaded: ["system/com.vendor.daemon", "gui/501/com.vendor.agent"])
        let items = await scan(mac, launchd: launchd)
        let daemon = try #require(item(items, "com.vendor.daemon"))
        let agent = try #require(item(items, "com.vendor.agent"))
        // No helper: nothing is run.
        #expect(await toggler(mac, launchd: launchd).setEnabled(false, daemon) == .needsHelper)
        #expect(await launchd.calls.allSatisfy { SystemLaunchctl.readOnlyVerbs.contains($0[0]) })

        let helper = SimulatedLaunchJobSwitch(systemRoot: mac.root, uid: Self.uid, launchctl: launchd)
        #expect(await toggler(mac, launchd: launchd, privileged: helper).setEnabled(false, daemon) == .done)
        #expect(await toggler(mac, launchd: launchd, privileged: helper).setEnabled(false, agent) == .done)
        #expect(await launchd.overrides["system"]?["com.vendor.daemon"] == true)
        // Agents in /Library are switched in the user's GUI domain.
        #expect(await launchd.overrides["gui/501"]?["com.vendor.agent"] == true)
        #expect(await launchd.loaded.isEmpty)
    }

    @Test func refusesWhatMayNotBeSwitched() async throws {
        let mac = try makeMac()
        let launchd = SimulatedLaunchctl()
        let items = await scan(mac, launchd: launchd)
        let helper = SimulatedLaunchJobSwitch(systemRoot: mac.root, uid: Self.uid, launchctl: launchd)
        for label in ["net.other.label", "com.example.sync.helper", "com.example.sync.agent"] {
            let blocked = try #require(item(items, label))
            #expect(await toggler(mac, launchd: launchd, privileged: helper).setEnabled(false, blocked) == .notAllowed)
        }
        // The file changed after the scan: its label is someone else's now.
        let agent = try #require(item(items, "com.dropbox.updater"))
        try mac.plist("Library/LaunchAgents/com.dropbox.updater.plist", ["Label": "com.apple.Finder", "Program": "/bin/ls"])
        #expect(await toggler(mac, launchd: launchd).setEnabled(false, agent) == .notAllowed)
        #expect(await launchd.calls.allSatisfy { SystemLaunchctl.readOnlyVerbs.contains($0[0]) })
    }

    @Test func theSimulatedHelperKeepsToItsFolders() async throws {
        let mac = try makeMac()
        let launchd = SimulatedLaunchctl()
        let helper = SimulatedLaunchJobSwitch(systemRoot: mac.root, uid: Self.uid, launchctl: launchd)
        let userAgent = mac.home.appending(path: "Library/LaunchAgents/com.dropbox.updater.plist").fsPath
        #expect(await helper.setLaunchJob(label: "com.dropbox.updater", plistPath: userAgent, enabled: false) != nil)
        let apple = mac.root.appending(path: "Library/LaunchDaemons/com.apple.ftpd.plist").fsPath
        #expect(await helper.setLaunchJob(label: "com.apple.ftpd", plistPath: apple, enabled: false) != nil)
        #expect(await launchd.calls.isEmpty)
    }
}
