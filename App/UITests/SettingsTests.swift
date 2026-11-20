import XCTest

final class SettingsTests: MacWashingUITestCase {
    func testSoundRemovalAndConfirmControls() {
        launch()
        click("sidebar.settings")

        // Sound (launched with -sound NO).
        assertValue("settings.sound", "выключено")
        click("settings.sound")
        assertValue("settings.sound", "включено")
        click("settings.sound")
        assertValue("settings.sound", "выключено")

        // Removal modes.
        XCTAssertTrue(waitFor("settings.junkRemoval.0").isSelected)
        click("settings.junkRemoval.1")
        XCTAssertTrue(wait { element("settings.junkRemoval.1").isSelected })
        XCTAssertFalse(element("settings.junkRemoval.0").isSelected)
        XCTAssertTrue(element("settings.otherRemoval.0").isSelected)
        click("settings.otherRemoval.1")
        XCTAssertTrue(wait { element("settings.otherRemoval.1").isSelected })

        // Confirmation.
        assertValue("settings.confirm", "включено")
        click("settings.confirm")
        assertValue("settings.confirm", "выключено")

        // Exclusions start empty; the picker button is there.
        XCTAssertFalse(element("settings.exclusion.remove").exists)
        XCTAssertTrue(element("settings.exclusion.add").exists)
    }

    func testExclusionHidesFolderFromJunkScanAndCanBeRemoved() throws {
        try tree.makeJunkFixture()
        let excluded = try tree.folder("Library/Caches/org.keep.me")
        try tree.file("Library/Caches/org.keep.me/a.bin", bytes: 50_000)
        launch(exclusions: [excluded.fsPath])

        click("sidebar.settings")
        waitFor("settings.exclusion.remove")
        waitForText(containing: "org.keep.me")

        app.typeKey("1", modifierFlags: .command)
        click("intro.start")
        waitFor("junk.toggleAll", timeout: 90)
        XCTAssertTrue(element("junk.entry.Fake").exists)
        XCTAssertFalse(element("junk.entry.org.keep.me").exists, "Excluded folder must not be reported")

        click("sidebar.settings")
        click("settings.exclusion.remove")
        XCTAssertTrue(wait { !element("settings.exclusion.remove").exists })
        XCTAssertTrue(wait { !text(containing: "org.keep.me").exists })

        app.typeKey("1", modifierFlags: .command)
        click("header.back")
        click("intro.start")
        waitFor("junk.toggleAll", timeout: 90)
        assertValue("junk.entry.org.keep.me", "выбрано")
    }
}
