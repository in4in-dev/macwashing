import Foundation
import XCTest

/// «Автозапуск» against launch jobs inside the sandbox. launchd is simulated there: every switch only writes the
/// launchctl command it would run to `root/launchctl-calls.log`, so nothing touches the real startup items of this Mac.
final class StartupTests: MacWashingUITestCase {
    // The section is hidden from the sidebar for now (AppSection.modules); bring these back with it.
    override func setUpWithError() throws {
        throw XCTSkip("«Автозапуск» is hidden from the sidebar")
    }

    private var log: URL { tree.root.appending(path: "launchctl-calls.log") }
    private var uid: uid_t { getuid() }

    private func makeFixture() throws {
        try tree.app("Syncer", bundleID: "com.example.syncer")
        try tree.file("usr/local/bin/vendord", in: tree.root)
        try tree.plist("Library/LaunchAgents/com.example.syncer.agent.plist", [
            "Label": "com.example.syncer.agent", "RunAtLoad": true,
            "ProgramArguments": ["~/Applications/Syncer.app/Contents/MacOS/Syncer", "--background"],
        ])
        try tree.plist("Library/LaunchAgents/org.dead.agent.plist", [
            "Label": "org.dead.agent", "Program": "/Applications/Gone.app/Contents/MacOS/agent",
        ])
        try tree.plist("Library/LaunchDaemons/com.vendor.daemon.plist", [
            "Label": "com.vendor.daemon", "Program": "/usr/local/bin/vendord", "KeepAlive": true,
        ], in: tree.root)
        try tree.app("Helper", bundleID: "com.example.syncer.helper",
                     in: tree.home.appending(path: "Applications/Syncer.app/Contents/Library/LoginItems"))
    }

    private func calls() -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func testListsStartupItemsAndSwitchesThemOnlyThroughTheSimulatedLaunchd() throws {
        try makeFixture()
        launch()
        click("sidebar.startup")
        click("intro.start")
        waitFor("startup.group.loginItem", timeout: 30)
        for kind in ["userAgent", "systemDaemon"] { waitFor("startup.group.\(kind)") }
        waitFor("startup.row.com.example.syncer.agent")
        waitFor("startup.settings.com.example.syncer.helper")
        waitFor("startup.broken.org.dead.agent")
        XCTAssertFalse(element("startup.toggle.com.example.syncer.helper").exists)

        // A user agent switches right away, as the user.
        assertValue("startup.toggle.com.example.syncer.agent", "включено")
        click("startup.toggle.com.example.syncer.agent")
        assertValue("startup.toggle.com.example.syncer.agent", "выключено")
        XCTAssertTrue(wait { self.calls().contains("launchctl disable gui/\(self.uid)/com.example.syncer.agent") }, "\(calls())")
        XCTAssertTrue(calls().contains("launchctl bootout gui/\(uid)/com.example.syncer.agent"))

        // Filters: the agent is off now; the dead agent is broken.
        click("startup.filter.2")
        waitFor("startup.row.com.example.syncer.agent")
        XCTAssertFalse(element("startup.row.com.vendor.daemon").exists)
        click("startup.filter.3")
        waitFor("startup.row.org.dead.agent")
        XCTAssertFalse(element("startup.row.com.example.syncer.agent").exists)
        click("startup.filter.0")

        // A system daemon asks first; cancel changes nothing.
        click("startup.toggle.com.vendor.daemon")
        assertLabel("confirm.title", "Выключить «com.vendor.daemon»?")
        click("confirm.cancel")
        waitGone("confirm.title")
        XCTAssertFalse(calls().contains { $0.contains("com.vendor.daemon") })
        click("startup.toggle.com.vendor.daemon")
        click("confirm.ok")
        assertValue("startup.toggle.com.vendor.daemon", "выключено")
        XCTAssertTrue(calls().contains("launchctl disable system/com.vendor.daemon"), "\(calls())")

        // Back on: enable + bootstrap of the same plist; the files never change.
        click("startup.toggle.com.example.syncer.agent")
        assertValue("startup.toggle.com.example.syncer.agent", "включено")
        let plist = tree.home.appending(path: "Library/LaunchAgents/com.example.syncer.agent.plist").fsPath
        XCTAssertTrue(calls().contains("launchctl bootstrap gui/\(uid) \(plist)"), "\(calls())")
        XCTAssertTrue(tree.exists(URL(filePath: plist)))
    }

    func testSearchNarrowsTheList() throws {
        try makeFixture()
        launch()
        click("sidebar.startup")
        click("intro.start")
        waitFor("startup.row.com.example.syncer.agent", timeout: 30)
        typeInSearch("vendor")
        waitFor("startup.row.com.vendor.daemon")
        waitGone("startup.row.com.example.syncer.agent")
        click("search.clear")
        waitFor("startup.row.com.example.syncer.agent")
    }
}
