import XCTest

final class DiskTests: MacWashingUITestCase {
    private struct Fixture {
        var clip: URL, setup: URL, archive: URL, oldFolder: URL, document: URL
    }

    /// A home with folders of clearly different sizes, one hidden folder and a folder to delete from.
    private func makeFixture() throws -> Fixture {
        let fixture = try Fixture(
            clip: tree.largeFile("Movies/clip.mov", megabytes: 12),
            setup: tree.file("Downloads/Setup.dmg", bytes: 200_000),
            archive: tree.file("Downloads/old/archive.zip", bytes: 50_000),
            oldFolder: tree.home.appending(path: "Downloads/old"),
            document: tree.file("Documents/keep.txt", bytes: 3_000)
        )
        try tree.largeFile("Projects/app/.git/objects/pack.bin", megabytes: 3)
        try tree.file(".config/tool/settings.json", bytes: 4_000)
        return fixture
    }

    private func row(_ name: String) -> XCUIElement { element("disk.row.\(name)") }

    /// ⌘-click or Control-click.
    private func click(_ element: XCUIElement, with modifiers: XCUIElement.KeyModifierFlags) {
        XCUIElement.perform(withKeyModifiers: modifiers) { element.click() }
    }

    private func openDisk() {
        click("sidebar.disk")
        waitFor("disk.table")
        waitFor("disk.row.Movies")
    }

    func testSizesSortingHiddenFilesAndNavigation() throws {
        try makeFixture()
        launch()
        openDisk()
        assertLabel("disk.title", "tester")

        // Folder sizes arrive on their own; the biggest folder comes first.
        assertLabel("disk.size.Movies", contains: "МБ")
        assertLabel("disk.size.Projects", contains: "МБ")
        waitGone("disk.measuring", timeout: 30)
        XCTAssertLessThan(row("Movies").frame.minY, row("Projects").frame.minY)
        XCTAssertLessThan(row("Projects").frame.minY, row("Downloads").frame.minY)

        // Hidden items are counted but listed only on request.
        XCTAssertFalse(row(".config").exists)
        assertLabel("disk.summary", contains: "скрытых: 1")
        assertValue("disk.hidden", "выключено")
        click("disk.hidden")
        assertValue("disk.hidden", "включено")
        XCTAssertTrue(row(".config").waitForExistence(timeout: 5))
        click("disk.hidden")
        XCTAssertTrue(wait { !row(".config").exists })

        // Large rows: the same items and sizes, sorted from a menu instead of column headers.
        XCTAssertFalse(element("disk.sort").exists)
        click("disk.view.large")
        waitFor("disk.sort")
        XCTAssertTrue(row("Movies").waitForExistence(timeout: 5))
        assertLabel("disk.size.Movies", contains: "МБ")
        XCTAssertLessThan(row("Movies").frame.minY, row("Downloads").frame.minY)
        click("disk.view.list")
        waitGone("disk.sort")

        // Double-click opens a folder; Up comes back with that folder selected; Back and Forward follow the history.
        row("Downloads").doubleClick()
        assertLabel("disk.title", "Downloads")
        XCTAssertTrue(row("Setup.dmg").waitForExistence(timeout: 5))
        assertLabel("disk.size.old", contains: "КБ")
        click("disk.up")
        assertLabel("disk.title", "tester")
        waitForText(containing: "Выбрано: 1")
        click("disk.back")
        assertLabel("disk.title", "Downloads")
        click("disk.forward")
        assertLabel("disk.title", "tester")
    }

    func testSourceListNavigatesAndHighlightsThePlace() throws {
        try makeFixture()
        launch()
        openDisk()
        XCTAssertTrue(element("disk.place.home").isSelected)
        XCTAssertFalse(element("disk.place.desktop").exists, "Only folders that exist are listed")

        click("disk.place.downloads")
        assertLabel("disk.title", "Downloads")
        XCTAssertTrue(wait { element("disk.place.downloads").isSelected && !element("disk.place.home").isSelected })
        // Deeper than a favorite: the favorite holding it stays highlighted.
        row("old").doubleClick()
        assertLabel("disk.title", "old")
        XCTAssertTrue(element("disk.place.downloads").isSelected)

        // The startup disk opens at its root; Up stops there, the path bar starts with the disk.
        click("disk.place.startup")
        XCTAssertTrue(row("Users").waitForExistence(timeout: 10))
        XCTAssertTrue(element("disk.place.startup").isSelected)
        XCTAssertFalse(element("disk.up").isEnabled)
        XCTAssertEqual(element("disk.title").label, element("disk.path.0").label)

        // Source list clicks join the history.
        click("disk.back")
        assertLabel("disk.title", "old")
        click("disk.place.home")
        assertLabel("disk.title", "tester")
    }

    func testProtectedFoldersCannotBeDeleted() throws {
        let fixture = try makeFixture()
        launch()
        openDisk()
        let before = tree.snapshot()

        // A standard home folder: the action is off, and so is the context menu item.
        row("Documents").click()
        waitFor("disk.protected")
        XCTAssertFalse(element("action.primary").isEnabled)
        row("Documents").rightClick()
        let delete = app.menuItems["Удалить"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertFalse(delete.isEnabled)
        XCTAssertTrue(app.menuItems["Показать в Finder"].exists)
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.delete, modifierFlags: .command)
        XCTAssertFalse(element("confirm.title").waitForExistence(timeout: 2), "⌘⌫ does nothing on a protected item")
        tree.assertOnlyRemoved([], since: before)
        XCTAssertTrue(tree.exists(fixture.document))
    }

    func testDeleteSelectionAfterConfirmation() throws {
        let fixture = try makeFixture()
        // Confirmation is off in Settings: the Disk section asks anyway.
        launch(confirm: false)
        openDisk()
        row("Downloads").doubleClick()
        XCTAssertTrue(row("Setup.dmg").waitForExistence(timeout: 5))
        assertLabel("disk.size.old", contains: "КБ")
        let before = tree.snapshot()

        // ⌘⌫ on one file asks first; Cancel keeps everything.
        row("Setup.dmg").click()
        app.typeKey(.delete, modifierFlags: .command)
        assertLabel("confirm.title", "Удалить «Setup.dmg» навсегда?")
        click("confirm.cancel")
        waitGone("confirm.title")
        tree.assertOnlyRemoved([], since: before)

        // ⌘-click adds the folder; Control-click opens the menu for both, and one confirmation removes both.
        click(row("old"), with: .command)
        waitForText(containing: "Выбрано: 2")
        click(row("old"), with: .control)
        let delete = app.menuItems["Удалить"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertTrue(delete.isEnabled)
        delete.click()
        assertLabel("confirm.title", "Удалить объекты навсегда: 2?")
        assertLabel("confirm.message", contains: "Setup.dmg, old")
        click("confirm.ok")
        waitGone("confirm.title")
        assertLabel("toast.text", contains: "Удалено")

        tree.assertOnlyRemoved([fixture.setup, fixture.oldFolder], since: before)
        XCTAssertTrue(wait { !row("Setup.dmg").exists && !row("old").exists })
        XCTAssertFalse(tree.exists(fixture.archive))
        waitFor("disk.placeholder")
    }
}
