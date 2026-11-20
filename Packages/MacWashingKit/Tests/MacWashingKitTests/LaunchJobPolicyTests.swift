import Foundation
import MacWashingXPC
import Testing
@testable import MacWashingKit

/// What the helper checks before it switches a job in /Library, and what the app checks before it switches the user's
/// own agents. Pure logic plus files in a temporary folder: launchctl is never run.
@Suite("Launch job policy")
struct LaunchJobPolicyTests {
    static let daemon = "/Library/LaunchDaemons/com.vendor.daemon.plist"

    private func facts(
        _ path: String = daemon, resolved: String?? = nil, regular: Bool = true, owner: uid_t? = 0, writable: Bool = false,
        label: String? = "com.vendor.daemon", program: String? = "/Library/Application Support/Vendor/daemon",
        resolvedProgram: String? = nil
    ) -> LaunchJobFacts {
        LaunchJobFacts(plistPath: path, resolvedPath: resolved ?? path, isRegularFile: regular, ownerUID: owner,
                       writableByOthers: writable, label: label, program: program, resolvedProgram: resolvedProgram)
    }

    // MARK: Labels

    @Test(arguments: ["com.vendor.agent", "homebrew.mxcl.postgresql@14", "postgresql-17", "org.tor_project.tor", "7zip.helper"])
    func allowsThirdPartyLabels(_ label: String) {
        #expect(SafetyPolicy.launchLabelAllowed(label))
    }

    @Test(arguments: [
        "", "-w", ".hidden", "com.apple.Siri.agent", "COM.APPLE.x", "com.apple",
        "com.ovvi.MacWashing.Helper", "com.ovvi.macwashing", "com.ovvi.MacWashing",
        "a/b", "a b", "vendor.агент", "a\nb", String(repeating: "a", count: 256),
    ])
    func refusesOtherLabels(_ label: String) {
        #expect(!SafetyPolicy.launchLabelAllowed(label))
    }

    @Test func refusesProgramsInsideSystem() {
        #expect(!SafetyPolicy.launchProgramAllowed("/System/Library/CoreServices/agent"))
        #expect(!SafetyPolicy.launchProgramAllowed("/system/library/agent"))
        #expect(!SafetyPolicy.launchProgramAllowed("/usr/local/bin/tool", resolved: "/System/Library/tool"))
        #expect(SafetyPolicy.launchProgramAllowed("/Applications/App.app/Contents/MacOS/App"))
        #expect(SafetyPolicy.launchProgramAllowed("/SystemTools/agent"))
        #expect(SafetyPolicy.launchProgramAllowed(nil))
    }

    // MARK: Folders

    @Test func knowsTheTwoPrivilegedFolders() {
        #expect(SafetyPolicy.privilegedLaunchFolder(of: "/Library/LaunchDaemons/com.vendor.daemon.plist") == .daemons)
        #expect(SafetyPolicy.privilegedLaunchFolder(of: "/Library/LaunchAgents/com.vendor.agent.plist") == .agents)
        #expect(PrivilegedLaunchFolder.agents.domain(clientUID: 501) == "gui/501")
        #expect(PrivilegedLaunchFolder.daemons.domain(clientUID: 501) == "system")
    }

    @Test(arguments: [
        "/System/Library/LaunchDaemons/com.vendor.daemon.plist", "/Library/LaunchDaemons/sub/com.vendor.daemon.plist",
        "/Library/LaunchDaemons/../LaunchDaemons/com.vendor.daemon.plist", "/Library/LaunchDaemons/./x.plist",
        "/Library/LaunchDaemons/.hidden.plist", "/Library/LaunchDaemons/.plist", "/Library/LaunchDaemons/com.vendor.daemon",
        "/Users/a/Library/LaunchAgents/com.vendor.agent.plist", "/Library/StartupItems/x.plist", "Library/LaunchDaemons/x.plist",
        "/library/launchdaemons/com.vendor.daemon.plist", "/Library/LaunchDaemons/",
    ])
    func refusesEveryOtherFolder(_ path: String) {
        #expect(SafetyPolicy.privilegedLaunchFolder(of: path) == nil)
        #expect(!SafetyPolicy.privilegedLaunchJobToggleAllowed(label: "com.vendor.daemon", facts: facts(path)))
    }

    // MARK: The helper's check

    @Test func allowsARootOwnedThirdPartyJob() {
        #expect(SafetyPolicy.privilegedLaunchJobToggleAllowed(label: "com.vendor.daemon", facts: facts()))
        let agent = "/Library/LaunchAgents/com.vendor.agent.plist"
        #expect(SafetyPolicy.privilegedLaunchJobToggleAllowed(label: "com.vendor.agent", facts: facts(agent, label: "com.vendor.agent")))
    }

    @Test func refusesASymlinkedPlist() {
        // A link in /Library/LaunchDaemons that points somewhere else: realpath differs from the path.
        #expect(!SafetyPolicy.privilegedLaunchJobToggleAllowed(label: "com.vendor.daemon", facts: facts(resolved: "/tmp/evil.plist")))
        #expect(!SafetyPolicy.privilegedLaunchJobToggleAllowed(label: "com.vendor.daemon", facts: facts(resolved: .some(nil))))
        #expect(!SafetyPolicy.privilegedLaunchJobToggleAllowed(label: "com.vendor.daemon", facts: facts(regular: false)))
    }

    @Test func refusesAppleLabelsAndOurOwnHelper() {
        for label in ["com.apple.ftpd", "com.ovvi.MacWashing.Helper"] {
            #expect(!SafetyPolicy.privilegedLaunchJobToggleAllowed(label: label, facts: facts("/Library/LaunchDaemons/\(label).plist", label: label)))
        }
    }

    @Test func refusesProgramsInSystem() {
        #expect(!SafetyPolicy.privilegedLaunchJobToggleAllowed(label: "com.vendor.daemon", facts: facts(program: "/System/Library/Tool")))
        #expect(!SafetyPolicy.privilegedLaunchJobToggleAllowed(
            label: "com.vendor.daemon", facts: facts(program: "/usr/local/bin/link", resolvedProgram: "/System/Library/Tool")))
    }

    @Test func refusesALabelThatIsNotTheFilesLabel() {
        #expect(!SafetyPolicy.privilegedLaunchJobToggleAllowed(label: "com.vendor.other", facts: facts()))
        #expect(!SafetyPolicy.privilegedLaunchJobToggleAllowed(label: "com.vendor.daemon", facts: facts(label: nil)))
    }

    @Test func refusesAPlistSomeoneElseCouldHaveWritten() {
        #expect(!SafetyPolicy.privilegedLaunchJobToggleAllowed(label: "com.vendor.daemon", facts: facts(owner: 501)))
        #expect(!SafetyPolicy.privilegedLaunchJobToggleAllowed(label: "com.vendor.daemon", facts: facts(owner: nil)))
        #expect(!SafetyPolicy.privilegedLaunchJobToggleAllowed(label: "com.vendor.daemon", facts: facts(writable: true)))
    }

    // MARK: Facts read from disk

    @Test func readsFactsAndSeesThroughSymlinks() throws {
        let mac = try FakeMac()
        try mac.plist("Jobs/real.plist", ["Label": "com.vendor.agent", "ProgramArguments": ["/bin/ls", "-l"]])
        let real = mac.home.appending(path: "Jobs/real.plist").fsPath
        let facts = LaunchJobFacts.read(plistPath: real)
        #expect(facts.isRegularFile)
        #expect(facts.resolvedPath == real)
        #expect(facts.label == "com.vendor.agent")
        #expect(facts.program == "/bin/ls")
        #expect(facts.ownerUID == getuid())
        #expect(!facts.writableByOthers)

        let link = mac.home.appending(path: "Jobs/link.plist").fsPath
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        let linked = LaunchJobFacts.read(plistPath: link)
        #expect(!linked.isRegularFile)
        #expect(linked.resolvedPath == real)

        chmod(real, 0o666)
        #expect(LaunchJobFacts.read(plistPath: real).writableByOthers)
        #expect(LaunchJobFacts.read(plistPath: mac.home.appending(path: "Jobs/missing.plist").fsPath).resolvedPath == nil)
    }

    // MARK: The app's own check (user agents)

    @Test func allowsTheUsersOwnAgents() throws {
        let mac = try FakeMac()
        try mac.plist("Library/LaunchAgents/com.vendor.agent.plist", ["Label": "com.vendor.agent", "Program": "/bin/ls"])
        try mac.plist("Library/LaunchAgents/com.apple.thing.plist", ["Label": "com.apple.thing", "Program": "/bin/ls"])
        try mac.plist("Library/LaunchAgents/mismatch.plist", ["Label": "com.vendor.real", "Program": "/bin/ls"])
        try mac.plist("Library/LaunchAgents/sub/com.vendor.nested.plist", ["Label": "com.vendor.nested"])
        try mac.plist("Library/LaunchAgents/com.vendor.system.plist", ["Label": "com.vendor.system", "Program": "/System/Library/x"])
        let home = mac.home.fsPath
        func allowed(_ name: String, _ label: String, home: String = home) -> Bool {
            let path = mac.home.appending(path: "Library/LaunchAgents/\(name)").fsPath
            return SafetyPolicy.userLaunchJobToggleAllowed(label: label, facts: .read(plistPath: path), home: home)
        }
        #expect(allowed("com.vendor.agent.plist", "com.vendor.agent"))
        #expect(allowed("com.vendor.agent.plist", "com.vendor.agent", home: home + "/"))
        #expect(!allowed("com.vendor.agent.plist", "com.vendor.agent", home: "/Users/someone"))
        #expect(!allowed("com.apple.thing.plist", "com.apple.thing"))
        #expect(!allowed("mismatch.plist", "mismatch"))
        #expect(!allowed("sub/com.vendor.nested.plist", "com.vendor.nested"))
        #expect(!allowed("com.vendor.system.plist", "com.vendor.system"))
        #expect(!allowed("gone.plist", "gone"))
    }

    // MARK: The steps

    @Test func turnsOffWithDisableAndBootout() async {
        let recorder = Recorder()
        let error = await LaunchJobPlan.apply(domain: "gui/501", label: "com.vendor.agent", plistPath: "/p.plist", enabled: false) {
            await recorder.run($0)
        }
        #expect(error == nil)
        #expect(await recorder.calls == [["disable", "gui/501/com.vendor.agent"], ["bootout", "gui/501/com.vendor.agent"]])
    }

    @Test func turnsOnWithEnableAndBootstrap() async {
        let recorder = Recorder()
        let error = await LaunchJobPlan.apply(domain: "system", label: "com.vendor.daemon", plistPath: "/p.plist", enabled: true) {
            await recorder.run($0)
        }
        #expect(error == nil)
        #expect(await recorder.calls == [["enable", "system/com.vendor.daemon"], ["bootstrap", "system", "/p.plist"]])
    }

    @Test func stopsWhenTheSwitchFails() async {
        let recorder = Recorder(fail: ["disable"])
        let error = await LaunchJobPlan.apply(domain: "gui/501", label: "com.vendor.agent", plistPath: "/p.plist", enabled: false) {
            await recorder.run($0)
        }
        #expect(error?.hasPrefix("launchctl disable failed (1)") == true)
        #expect(await recorder.calls == [["disable", "gui/501/com.vendor.agent"]])
    }

    @Test func aJobAlreadyWhereItShouldBeIsFine() async {
        // bootout of a job that is not loaded fails, but print says it is not loaded: done.
        let notLoaded = Recorder(fail: ["bootout", "print"])
        #expect(await LaunchJobPlan.apply(domain: "gui/501", label: "a.b.c", plistPath: "/p.plist", enabled: false) {
            await notLoaded.run($0)
        } == nil)
        // bootout failed and the job is still loaded: that is an error.
        let stillLoaded = Recorder(fail: ["bootout"])
        let error = await LaunchJobPlan.apply(domain: "gui/501", label: "a.b.c", plistPath: "/p.plist", enabled: false) {
            await stillLoaded.run($0)
        }
        #expect(error?.hasPrefix("launchctl bootout failed") == true)
    }
}

/// Records calls and fails the listed verbs.
actor Recorder {
    private(set) var calls: [[String]] = []
    let fail: Set<String>

    init(fail: Set<String> = []) {
        self.fail = fail
    }

    func run(_ arguments: [String]) -> LaunchctlResult {
        calls.append(arguments)
        return fail.contains(arguments.first ?? "") ? LaunchctlResult(status: 1, error: "nope") : LaunchctlResult(status: 0)
    }
}
