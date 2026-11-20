import XCTest

final class JunkTests: MacWashingUITestCase {
    private func scan() {
        click("intro.start")
        waitFor("progress.title", timeout: 10)
        assertLabel("progress.title", contains: "Ищу мусор")
        waitFor("junk.toggleAll", timeout: 90)
    }

    func testResultsSelectionExpandAndBack() throws {
        let fixture = try tree.makeJunkFixture()
        launch()
        scan()

        // Every category the fixture feeds is listed; the largest one is focused.
        for id in ["userCaches", "installers", "xcode", "userLogs", "leftovers", "afterRemoval", "systemLogs", "systemCaches", "brokenLoginItems"] {
            waitFor("junk.category.\(id)")
        }
        assertLabel("junk.detail.title", "Пользовательский кэш")
        assertLabel("junk.category.userCaches.subtitle", "3 из 4 выбрано")

        // User caches: app cache, a Google group, Gradle gray, Apple caches never listed.
        assertValue("junk.entry.Fake", "выбрано")
        assertValue("junk.entry.Google", "выбрано")
        assertValue("junk.entry.Gradle", "не выбрано")
        XCTAssertFalse(element("junk.entry.com.apple.Safari").exists)
        XCTAssertTrue(text(containing: "Осторожно").exists, "Gradle should carry the «Осторожно» pill")
        XCTAssertFalse(element("junk.entry.Chrome").exists, "Group children are hidden until expanded")

        assertLabel("junk.expand.Google", "Показать")
        click("junk.expand.Google")
        assertLabel("junk.expand.Google", "Скрыть")
        assertValue("junk.entry.Chrome", "выбрано")
        assertValue("junk.entry.AndroidStudio2026.1", "выбрано")

        click("junk.entry.AndroidStudio2026.1")
        assertValue("junk.entry.AndroidStudio2026.1", "не выбрано")
        assertValue("junk.entry.Google", "частично")
        assertLabel("junk.category.userCaches.subtitle", "2 из 4 выбрано")
        assertValue("junk.category.userCaches.check", "частично")

        click("junk.entry.Fake")
        assertValue("junk.entry.Fake", "не выбрано")
        assertLabel("junk.category.userCaches.subtitle", "1 из 4 выбрано")

        // Category checkbox toggles everything inside.
        assertValue("junk.category.installers.check", "выбрано")
        click("junk.category.installers.check")
        assertValue("junk.category.installers.check", "не выбрано")
        assertLabel("junk.category.installers.subtitle", "0 из 2 выбрано")
        click("junk.category.installers")
        assertLabel("junk.detail.title", "Установщики")
        assertValue("junk.entry.Setup.dmg", "не выбрано")
        assertValue("junk.entry.tool.pkg", "не выбрано")
        XCTAssertFalse(element("junk.entry.notes.txt").exists)
        click("junk.category.installers.check")
        assertValue("junk.entry.Setup.dmg", "выбрано")

        // Xcode: DerivedData checked, Archives gray.
        click("junk.category.xcode")
        assertLabel("junk.detail.title", "Мусор Xcode")
        assertValue("junk.entry.DerivedData", "выбрано")
        assertValue("junk.entry.Archives", "не выбрано")
        click("junk.expand.Archives")
        assertValue("junk.entry.2026-09-01", "не выбрано")

        // Leftovers of a removed app, a broken preference and a broken launch agent.
        click("junk.category.leftovers")
        assertLabel("junk.detail.title", "Остатки программ")
        assertValue("junk.entry.Evernote", "выбрано")
        // The rest of Evernote's fingerprint, outside the folders the leftovers scan looks in.
        click("junk.category.afterRemoval")
        assertLabel("junk.detail.title", "Осталось после удаления")
        assertValue("junk.entry.Evernote", "выбрано")
        click("junk.category.brokenLoginItems")
        assertValue("junk.entry.org.dead.agent", "выбрано")
        XCTAssertFalse(element("junk.entry.org.alive.agent").exists)
        click("junk.category.systemLogs")
        assertValue("junk.entry.system.log", "выбрано")
        click("junk.category.systemCaches")
        assertValue("junk.entry.org.vendor.cache", "выбрано")
        click("junk.category.userLogs")
        assertValue("junk.entry.app.log", "выбрано")

        // The scan checks only the regular items; «Выбрать все» takes literally everything, gray items too.
        assertLabel("junk.toggleAll", "Выбрать все")
        click("junk.toggleAll")
        assertLabel("junk.category.userCaches.subtitle", "4 из 4 выбрано")
        assertLabel("junk.toggleAll", "Снять все")
        click("junk.toggleAll")
        assertLabel("junk.category.userCaches.subtitle", "0 из 4 выбрано")
        XCTAssertTrue(wait { !element("action.primary").isEnabled })
        click("junk.toggleAll")
        XCTAssertTrue(wait { element("action.primary").isEnabled })

        // Back to the intro and a second scan gives the same picture; nothing was deleted.
        let before = tree.snapshot()
        click("header.back")
        waitFor("intro.start")
        scan()
        assertLabel("junk.category.userCaches.subtitle", "3 из 4 выбрано")
        tree.assertOnlyRemoved([], since: before)
        XCTAssertTrue(tree.exists(fixture.chrome))
    }

    func testSearchAcrossResults() throws {
        try tree.makeJunkFixture()
        launch()
        scan()

        typeInSearch("chrome")
        assertLabel("junk.search.summary", contains: "найдено 1")
        assertLabel("junk.category.userCaches.subtitle", "Совпадений: 1")
        XCTAssertTrue(wait { !element("junk.category.installers").exists }, "Categories without hits leave the list")
        assertValue("junk.entry.Chrome", "выбрано")
        XCTAssertTrue(text(containing: "Пользовательский кэш › Google").exists, "Hit shows its category and group")

        assertLabel("junk.selectFound", "Снять найденное")
        click("junk.selectFound")
        assertValue("junk.entry.Chrome", "не выбрано")
        assertLabel("junk.selectFound", "Выбрать найденное")
        click("junk.selectFound")
        assertValue("junk.entry.Chrome", "выбрано")

        click("search.clear")
        XCTAssertTrue(wait { element("junk.category.installers").exists })
        typeInSearch("zzz-nothing")
        waitForText(containing: "Ничего не найдено")
        XCTAssertFalse(element("junk.selectFound").isEnabled)

        click("search.clear")
        typeInSearch("evernote")
        assertLabel("junk.search.summary", contains: "найдено 1")
        assertValue("junk.entry.Evernote", "выбрано")

        // Picking a category leaves the search.
        click("junk.category.leftovers")
        assertLabel("junk.detail.title", "Остатки программ")
        XCTAssertTrue(wait { (element("search.field").value as? String ?? "").isEmpty }, "Search field should be cleared")
        XCTAssertTrue(wait { element("junk.category.installers").exists })
    }

    func testCleanRemovesExactlyTheCheckedItems() throws {
        let fixture = try tree.makeJunkFixture()
        launch()
        scan()
        let before = tree.snapshot()

        click("junk.entry.Fake")
        click("junk.expand.Google")
        click("junk.entry.AndroidStudio2026.1")
        click("junk.category.installers.check")
        assertValue("junk.category.installers.check", "не выбрано")

        assertLabel("action.primary", "Очистить")
        click("action.primary")
        waitFor("progress.title", timeout: 10)
        assertLabel("progress.title", contains: "Очищаю")
        waitFor("done.finish", timeout: 60)
        assertLabel("done.stat.1", "9")
        assertLabel("done.stat.2", "0")
        XCTAssertFalse(text(containing: "Пропущено, программы были открыты").exists)

        tree.assertOnlyRemoved([
            fixture.chrome, fixture.derivedData, fixture.log, fixture.evernoteSupport, fixture.evernotePlist,
            fixture.brokenPlist, fixture.deadAgent, fixture.systemLog, fixture.systemCache,
        ], since: before)
        XCTAssertTrue(tree.exists(fixture.fakeCache))
        XCTAssertTrue(tree.exists(fixture.androidStudio))
        XCTAssertTrue(tree.exists(fixture.gradle))
        XCTAssertTrue(tree.exists(fixture.archive))
        XCTAssertTrue(tree.exists(fixture.dmg))
        XCTAssertTrue(tree.exists(fixture.pkg))
        XCTAssertTrue(tree.exists(fixture.safariCache))
        XCTAssertTrue(tree.exists(fixture.goodPlist))
        XCTAssertTrue(tree.exists(fixture.aliveAgent))
        XCTAssertTrue(tree.exists(fixture.document))

        click("done.finish")
        waitFor("intro.start")
    }

    func testStopDuringScanReturnsToIntro() throws {
        try tree.makeJunkFixture()
        // Enough small files to keep the scan busy for a moment.
        for index in 0..<400 {
            try tree.file("Library/Caches/com.fake.app/part\(index).bin", bytes: 2_048)
            try tree.file("Library/Logs/log\(index).log", bytes: 2_048)
        }
        launch()
        let before = tree.snapshot()
        click("intro.start")
        let stop = element("progress.stop")
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "Scan finished before it could be stopped")
        stop.click()
        waitFor("intro.start", timeout: 10)
        XCTAssertFalse(element("junk.toggleAll").exists, "Stopping must not show results")
        XCTAssertFalse(element("progress.stop").exists)
        tree.assertOnlyRemoved([], since: before)
    }
}
