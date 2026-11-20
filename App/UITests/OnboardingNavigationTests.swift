import XCTest

final class OnboardingNavigationTests: MacWashingUITestCase {
    func testOnboardingLaterLeadsIntoTheApp() {
        launch(onboarded: false)
        waitForText(containing: "Два разрешения")
        XCTAssertTrue(element("onboarding.start").exists)
        XCTAssertFalse(element("sidebar.junk").exists, "Sidebar must not show during onboarding")

        click("onboarding.later")

        waitFor("sidebar.junk")
        waitFor("intro.start")
        XCTAssertTrue(wait { !text(containing: "Два разрешения").exists })
        XCTAssertEqual(element("intro.start").label, "Начать сканирование")
    }

    func testSidebarAndKeyboardNavigation() {
        launch()
        waitFor("sidebar.junk")
        XCTAssertTrue(element("sidebar.junk").isSelected)
        XCTAssertFalse(element("sidebar.largeFiles").isSelected)

        click("sidebar.largeFiles")
        XCTAssertTrue(wait { element("sidebar.largeFiles").isSelected })
        waitForText(containing: "Где искать")

        click("sidebar.uninstaller")
        XCTAssertTrue(wait { element("sidebar.uninstaller").isSelected })
        XCTAssertEqual(waitFor("intro.start").label, "Показать программы")

        click("sidebar.settings")
        XCTAssertTrue(wait { element("sidebar.settings").isSelected })
        waitFor("settings.sound")

        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(wait { element("sidebar.junk").isSelected })
        XCTAssertEqual(waitFor("intro.start").label, "Начать сканирование")

        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(wait { element("sidebar.largeFiles").isSelected })
        XCTAssertEqual(waitFor("intro.start").label, "Найти большие файлы")

        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(wait { element("sidebar.uninstaller").isSelected })

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(wait { element("sidebar.settings").isSelected })
        waitFor("settings.sound")
    }
}
