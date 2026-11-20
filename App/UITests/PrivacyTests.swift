import Foundation
import SQLite3
import XCTest

/// «Приватность» against fake TCC databases inside the sandbox. Resets only write the tccutil command they would run to
/// `root/tccutil-calls.log`: nothing touches the real permissions of this Mac.
final class PrivacyTests: MacWashingUITestCase {
    private static let schema = """
        CREATE TABLE access (service TEXT NOT NULL, client TEXT NOT NULL, client_type INTEGER NOT NULL,
            auth_value INTEGER NOT NULL, auth_reason INTEGER NOT NULL, auth_version INTEGER NOT NULL, csreq BLOB,
            policy_id INTEGER, indirect_object_identifier_type INTEGER, indirect_object_identifier TEXT NOT NULL DEFAULT 'UNUSED',
            indirect_object_code_identity BLOB, flags INTEGER, last_modified INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
            pid INTEGER, pid_version INTEGER, boot_uuid TEXT NOT NULL DEFAULT 'UNUSED', last_reminded INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (service, client, client_type, indirect_object_identifier));
        """

    /// (service suffix, client, client type, auth value, indirect object)
    private func database(_ url: URL, _ rows: [(String, String, Int, Int, String)]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.fsPath, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let inserts = rows.map { row in
            "INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier, last_modified) "
                + "VALUES ('kTCCService\(row.0)', '\(row.1)', \(row.2), \(row.3), 2, 1, '\(row.4)', 1760000000);"
        }
        XCTAssertEqual(sqlite3_exec(handle, Self.schema + inserts.joined(), nil, nil, nil), SQLITE_OK)
    }

    private var userDatabase: URL { tree.home.appending(path: "Library/Application Support/com.apple.TCC/TCC.db") }
    private var log: URL { tree.root.appending(path: "tccutil-calls.log") }

    private func makeFixture() throws {
        try tree.app("Zoom", bundleID: "com.example.zoom")
        try tree.app("Target", bundleID: "com.example.target")
        try database(userDatabase, [
            ("Camera", "com.example.zoom", 0, 2, "UNUSED"),
            ("Camera", "/usr/local/bin/tool", 1, 2, "UNUSED"),
            ("Camera", "com.example.gone", 0, 2, "UNUSED"),
            ("Camera", "com.example.denied", 0, 0, "UNUSED"),
            ("Microphone", "com.example.zoom", 0, 2, "UNUSED"),
            ("Reminders", "com.example.zoom", 0, 0, "UNUSED"),
            ("AppleEvents", "com.example.zoom", 0, 2, "com.example.target"),
        ])
        try database(tree.root.appending(path: "Library/Application Support/com.apple.TCC/TCC.db"), [
            ("ScreenCapture", "com.example.zoom", 0, 2, "UNUSED"),
        ])
    }

    private func calls() -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func testListsPermissionsAndResetsOnlyThroughTheRunner() throws {
        try makeFixture()
        launch()
        click("sidebar.privacy")
        click("intro.start")
        waitFor("privacy.category.camera", timeout: 30)
        for id in ["microphone", "screenRecording", "automation", "location"] { waitFor("privacy.category.\(id)") }
        // Only apps that have access are listed: a type with nothing but a denial is not shown.
        XCTAssertFalse(element("privacy.category.reminders").exists)

        // Camera: a path client can only be changed in System Settings.
        click("privacy.category.camera")
        assertLabel("privacy.title", "Камера")
        assertLabel("privacy.subtitle", "Программ с доступом: 3")
        XCTAssertFalse(element("privacy.row.Camera.com.example.denied").exists)
        waitFor("privacy.reset.Camera.com.example.zoom")
        waitFor("privacy.reset.Camera.com.example.gone")
        waitFor("privacy.settings.Camera./usr/local/bin/tool")
        XCTAssertFalse(element("privacy.reset.Camera./usr/local/bin/tool").exists)
        waitForText(containing: "Программа удалена")

        // Cancel leaves everything as it was.
        click("privacy.reset.Camera.com.example.zoom")
        assertLabel("confirm.title", "Запретить доступ «Камера» для Zoom?")
        waitForText(containing: "Zoom сразу потеряет доступ и сможет запросить его снова позже.")
        click("confirm.cancel")
        waitGone("confirm.title")
        XCTAssertTrue(calls().isEmpty)

        click("privacy.reset.Camera.com.example.zoom")
        click("confirm.ok")
        waitGone("privacy.row.Camera.com.example.zoom")
        assertLabel("toast.text", contains: "Доступ запрещён: Zoom")
        XCTAssertEqual(calls(), ["user: tccutil reset Camera com.example.zoom"])

        // A system-wide decision goes to the system runner (the helper on a real Mac).
        click("privacy.category.screenRecording")
        click("privacy.reset.ScreenCapture.com.example.zoom")
        click("confirm.ok")
        waitGone("privacy.row.ScreenCapture.com.example.zoom")
        XCTAssertEqual(calls().last, "system: tccutil reset ScreenCapture com.example.zoom")
        waitGone("privacy.category.screenRecording")

        // Automation shows «app → target»; search keeps only matching types.
        click("privacy.category.automation")
        waitFor("privacy.row.AppleEvents.com.example.zoom→com.example.target")
        typeInSearch("target")
        XCTAssertTrue(wait { !element("privacy.category.microphone").exists })
        waitFor("privacy.category.automation")
        click("search.clear")
        waitFor("privacy.category.microphone")

        click("privacy.category.location")
        assertLabel("privacy.title", "Службы геолокации")
        waitFor("privacy.openSettings")
        XCTAssertEqual(calls().count, 2)
    }

    func testAsksForFullDiskAccessWhenTheDatabaseIsUnreadable() throws {
        try makeFixture()
        chmod(userDatabase.fsPath, 0)
        defer { chmod(userDatabase.fsPath, 0o644) }
        launch()
        click("sidebar.privacy")
        waitFor("privacy.noAccess")
        waitFor("privacy.grantAccess")
        XCTAssertFalse(element("intro.start").isEnabled)
    }
}
