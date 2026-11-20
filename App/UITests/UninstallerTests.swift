import XCTest

final class UninstallerTests: MacWashingUITestCase {
    private func openList() {
        click("sidebar.uninstaller")
        click("intro.start")
        waitFor("uninstaller.sort.0", timeout: 60)
    }

    func testListSortSearchAndSelection() throws {
        let fixture = try tree.makeUninstallerFixture()
        launch()
        openList()

        // Apps from ~/Applications, the fake /Applications and the fake /System/Applications are all listed.
        for name in ["Alpha", "Beta", "Gamma", "SysApp"] { waitFor("uninstaller.app.\(name)") }
        XCTAssertFalse(element("uninstaller.app.SysApp.check").exists, "System apps have no checkbox")
        XCTAssertTrue(element("uninstaller.sort.0").isSelected)
        click("uninstaller.sort.1")
        XCTAssertTrue(wait { element("uninstaller.sort.1").isSelected })
        XCTAssertFalse(element("uninstaller.sort.0").isSelected)
        click("uninstaller.sort.2")
        XCTAssertTrue(wait { element("uninstaller.sort.2").isSelected })
        click("uninstaller.sort.0")

        // Nothing in the fixture has a last-used date, so nothing counts as unused.
        assertLabel("uninstaller.selectUnused", "Выбрать неиспользуемые · 0")
        XCTAssertFalse(element("uninstaller.selectUnused").isEnabled)

        typeInSearch("alp")
        XCTAssertTrue(wait { !element("uninstaller.app.Beta").exists })
        XCTAssertTrue(element("uninstaller.app.Alpha").exists)
        click("search.clear")
        typeInSearch("nothing-here")
        waitForText(containing: "Ничего не найдено")
        click("search.clear")
        XCTAssertTrue(wait { element("uninstaller.app.Beta").exists })

        click("uninstaller.app.SysApp")
        assertLabel("uninstaller.modePill", "Защищена")
        waitForText(containing: "Системные программы Apple защищены")

        click("uninstaller.app.Alpha")
        assertLabel("uninstaller.itemCount", "Состав · 6")
        assertLabel("uninstaller.modePill", "Не выбрана")
        waitForText(containing: "Версия 1.0 · Example Corp")
        for item in ["~/Library/Caches/com.example.alpha", "~/Library/Preferences/com.example.alpha.plist",
                     "~/Library/Application Support/Alpha", "~/Library/Containers/com.example.alpha",
                     "~/Library/LaunchAgents/com.example.alpha.helper.plist"] {
            assertValue("uninstaller.item.\(item)", "не выбрано")
        }
        XCTAssertFalse(element("uninstaller.item.~/Library/Caches/com.other.thing").exists)

        click("uninstaller.app.Alpha.check")
        assertValue("uninstaller.app.Alpha.check", "выбрано")
        assertLabel("uninstaller.modePill", "Удаляется полностью")
        assertLabel("uninstaller.toggleFocused", "Снять всё")
        waitForText(containing: "Выбрано программ: 1")

        click("uninstaller.item.~/Library/Application Support/Alpha")
        assertValue("uninstaller.app.Alpha.check", "частично")
        assertLabel("uninstaller.modePill", "Удаляется, часть файлов останется")
        assertLabel("uninstaller.toggleFocused", "Выбрать всё")

        click("uninstaller.app.Beta")
        assertLabel("uninstaller.itemCount", "Состав · 4")
        click("uninstaller.item.~/Library/Caches/com.example.beta")
        assertLabel("uninstaller.modePill", "Только выбранные папки")
        assertValue("uninstaller.app.Beta.check", "частично")
        waitForText(containing: "Выбрано программ: 1, объектов: 1")

        click("uninstaller.clearSelection")
        waitForText(containing: "Ничего не выбрано")
        assertValue("uninstaller.app.Beta.check", "не выбрано")
        assertValue("uninstaller.app.Alpha.check", "не выбрано")
        XCTAssertFalse(element("action.primary").isEnabled)
        XCTAssertTrue(tree.exists(fixture.alpha))

        click("header.back")
        waitFor("intro.start")
    }

    func testUninstallRemovesOnlyChosenItems() throws {
        let fixture = try tree.makeUninstallerFixture()
        launch()
        openList()
        let before = tree.snapshot()

        click("uninstaller.app.Alpha")
        click("uninstaller.app.Alpha.check")
        assertLabel("uninstaller.modePill", "Удаляется полностью")
        click("uninstaller.item.~/Library/Application Support/Alpha")
        click("uninstaller.app.Beta")
        click("uninstaller.item.~/Library/Caches/com.example.beta")
        waitForText(containing: "Выбрано программ: 1, объектов: 1")

        click("action.primary")
        assertLabel("confirm.title", "Удалить программы (1) и папки (1)?")
        click("confirm.cancel")
        waitGone("confirm.title")
        tree.assertOnlyRemoved([], since: before)

        click("action.primary")
        assertLabel("confirm.title", "Удалить программы (1) и папки (1)?")
        click("confirm.ok")
        waitGone("confirm.title")
        assertLabel("toast.text", contains: "Удалено")

        tree.assertOnlyRemoved([
            fixture.alpha, fixture.alphaCache, fixture.alphaPrefs, fixture.alphaContainer, fixture.alphaAgent, fixture.betaCache,
        ], since: before)
        XCTAssertTrue(tree.exists(fixture.alphaSupport))
        XCTAssertTrue(tree.exists(fixture.beta))
        XCTAssertTrue(tree.exists(fixture.betaPrefs))
        XCTAssertTrue(tree.exists(fixture.betaSupport))
        XCTAssertTrue(tree.exists(fixture.gamma))
        XCTAssertTrue(tree.exists(fixture.otherCache))

        XCTAssertTrue(wait { !element("uninstaller.app.Alpha").exists }, "Removed app leaves the list")
        XCTAssertTrue(element("uninstaller.app.Beta").exists)
        click("uninstaller.app.Beta")
        assertLabel("uninstaller.itemCount", "Состав · 3")
        waitForText(containing: "Ничего не выбрано")
    }
}
