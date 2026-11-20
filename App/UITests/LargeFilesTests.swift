import XCTest

final class LargeFilesTests: MacWashingUITestCase {
    /// Scans and waits until the background refine pass has finished.
    private func scanAndSettle() {
        click("intro.start")
        waitFor("largeFiles.toggleAll", timeout: 60)
        waitGone("largeFiles.refining", timeout: 90)
    }

    func testIntroVolumeToggleAndFilters() throws {
        try tree.makeLargeFilesFixture()
        launch()
        click("sidebar.largeFiles")
        waitForText(containing: "Где искать")

        // The (real) startup volume is the only row inside the sandbox; unchecking it disables the start button.
        assertValue("largeFiles.volume.0", "выбрано")
        XCTAssertFalse(element("largeFiles.volume.1").exists, "Only the startup volume is offered in the sandbox")
        XCTAssertTrue(element("intro.start").isEnabled)
        click("largeFiles.volume.0")
        assertValue("largeFiles.volume.0", "не выбрано")
        XCTAssertTrue(wait { !element("intro.start").isEnabled })
        click("largeFiles.volume.0")
        XCTAssertTrue(wait { element("intro.start").isEnabled })

        scanAndSettle()
        assertLabel("largeFiles.summary", contains: "Файлов: 4")
        XCTAssertTrue(element("largeFiles.filter.all").isSelected)
        for name in ["clip.mov", "bundle.zip", "old-report.pdf", "keep.mov"] {
            assertValue("largeFiles.file.\(name)", "не выбрано")
        }
        XCTAssertFalse(element("largeFiles.file.small.png").exists)
        XCTAssertFalse(element("largeFiles.file.blob.bin").exists, "~/Library belongs to the junk module")

        click("largeFiles.filter.movie")
        XCTAssertTrue(wait { element("largeFiles.filter.movie").isSelected })
        assertLabel("largeFiles.summary", contains: "Файлов: 2")
        XCTAssertTrue(element("largeFiles.file.clip.mov").exists)
        XCTAssertFalse(element("largeFiles.file.bundle.zip").exists)

        // «Выбрать все» works on the shown files only.
        click("largeFiles.toggleAll")
        waitForText(containing: "Выбрано файлов: 2")
        assertLabel("largeFiles.toggleAll", "Снять все")
        click("largeFiles.toggleAll")
        waitForText(containing: "Ничего не выбрано")

        click("largeFiles.filter.archive")
        assertLabel("largeFiles.summary", contains: "Файлов: 1")
        XCTAssertTrue(element("largeFiles.file.bundle.zip").exists)
        click("largeFiles.filter.document")
        assertLabel("largeFiles.summary", contains: "Файлов: 1")
        XCTAssertTrue(element("largeFiles.file.old-report.pdf").exists)
        click("largeFiles.filter.image")
        assertLabel("largeFiles.summary", contains: "Файлов: 0")
        waitForText(containing: "Файлов больше 50 МБ здесь нет")

        click("largeFiles.filter.medium")
        assertLabel("largeFiles.summary", contains: "Файлов: 1")
        XCTAssertTrue(element("largeFiles.file.bundle.zip").exists)
        click("largeFiles.filter.small")
        assertLabel("largeFiles.summary", contains: "Файлов: 3")
        click("largeFiles.filter.huge")
        assertLabel("largeFiles.summary", contains: "Файлов: 0")

        click("largeFiles.filter.olderThanYear")
        assertLabel("largeFiles.summary", contains: "Файлов: 1")
        XCTAssertTrue(element("largeFiles.file.old-report.pdf").exists)
        click("largeFiles.filter.lastWeek")
        assertLabel("largeFiles.summary", contains: "Файлов: 3")
        click("largeFiles.filter.olderThanMonth")
        assertLabel("largeFiles.summary", contains: "Файлов: 0")
        click("largeFiles.filter.all")
        assertLabel("largeFiles.summary", contains: "Файлов: 4")

        click("header.back")
        waitForText(containing: "Где искать")
    }

    func testDeleteSelectedWithConfirmation() throws {
        let fixture = try tree.makeLargeFilesFixture()
        launch()
        click("sidebar.largeFiles")
        scanAndSettle()
        let before = tree.snapshot()

        XCTAssertFalse(element("action.primary").isEnabled)
        click("largeFiles.file.clip.mov")
        click("largeFiles.file.old-report.pdf")
        assertValue("largeFiles.file.clip.mov", "выбрано")
        waitForText(containing: "Выбрано файлов: 2")
        XCTAssertTrue(element("action.primary").isEnabled)
        assertLabel("action.primary", "В Корзину")

        // «Минуя Корзину» switches the wording of the button and the dialog.
        assertValue("largeFiles.deleteImmediately", "выключено")
        click("largeFiles.deleteImmediately")
        assertValue("largeFiles.deleteImmediately", "включено")
        assertLabel("action.primary", "Удалить")

        click("action.primary")
        assertLabel("confirm.title", "Удалить файлы навсегда: 2?")
        click("confirm.cancel")
        waitGone("confirm.title")
        tree.assertOnlyRemoved([], since: before)

        click("largeFiles.deleteImmediately")
        assertValue("largeFiles.deleteImmediately", "выключено")
        click("action.primary")
        assertLabel("confirm.title", "Переместить в Корзину файлы: 2?")
        click("confirm.ok")
        waitGone("confirm.title")
        assertLabel("toast.text", contains: "2 файл.")

        tree.assertOnlyRemoved([fixture.clip, fixture.oldReport], since: before)
        XCTAssertTrue(wait { !element("largeFiles.file.clip.mov").exists })
        XCTAssertTrue(element("largeFiles.file.keep.mov").exists)
        assertLabel("largeFiles.summary", contains: "Файлов: 2")
        waitForText(containing: "Ничего не выбрано")
    }

    func testDeleteWithoutConfirmation() throws {
        let fixture = try tree.makeLargeFilesFixture()
        launch(confirm: false)
        click("sidebar.largeFiles")
        scanAndSettle()
        let before = tree.snapshot()

        click("largeFiles.file.bundle.zip")
        click("action.primary")
        XCTAssertFalse(element("confirm.title").waitForExistence(timeout: 2), "No dialog when confirmation is off")
        assertLabel("toast.text", contains: "1 файл.")
        tree.assertOnlyRemoved([fixture.archive], since: before)
    }

    func testStopDuringScan() throws {
        try tree.makeLargeFilesFixture()
        launch()
        click("sidebar.largeFiles")
        let before = tree.snapshot()
        click("intro.start")
        let stop = element("progress.stop")
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "Scan finished before it could be stopped")
        stop.click()
        waitForText(containing: "Где искать")
        XCTAssertFalse(element("largeFiles.toggleAll").exists)
        tree.assertOnlyRemoved([], since: before)
    }
}
