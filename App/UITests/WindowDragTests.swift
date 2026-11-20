import XCTest

/// Dragging the window (`windowBackgroundDragBehavior` on macOS 15+, nothing extra on 14): the title bar moves it, a list
/// row and a button never do. The other probes are only reported: each prints a `DRAG <name> moved=` line, so builds and
/// systems can be compared (on macOS 26 only the title bar strip moves the window). Run it in a virtual machine: it takes over the screen.
final class WindowDragTests: MacWashingUITestCase {
    private var window: XCUIElement { app.windows.firstMatch }

    /// Drags from `point` (relative to the window) by 80×50 points; whether the window followed.
    private func drag(_ name: String, from point: CGVector) -> Bool {
        let before = window.frame
        let start = window.coordinate(withNormalizedOffset: point)
        start.press(forDuration: 0.3, thenDragTo: start.withOffset(CGVector(dx: 80, dy: 50)))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let after = window.frame
        let moved = abs(after.minX - before.minX) > 20 || abs(after.minY - before.minY) > 20
        print("DRAG \(name) moved=\(moved) from=\(before.origin) to=\(after.origin)")
        return moved
    }

    func testTitleBarMovesTheWindowListsAndButtonsDoNot() throws {
        _ = try tree.makeUninstallerFixture()
        launch()
        waitFor("sidebar.uninstaller")

        XCTAssertTrue(drag("titlebar", from: CGVector(dx: 0.6, dy: 0.012)), "The title bar always moves the window")
        _ = drag("below-titlebar", from: CGVector(dx: 0.6, dy: 0.04))
        _ = drag("header-gap", from: CGVector(dx: 0.45, dy: 0.075))
        _ = drag("sidebar-header", from: CGVector(dx: 0.12, dy: 0.05))
        _ = drag("sidebar-top", from: CGVector(dx: 0.12, dy: 0.1))
        _ = drag("sidebar-water", from: CGVector(dx: 0.12, dy: 0.7))

        click("sidebar.uninstaller")
        waitFor("intro.start")
        _ = drag("intro-background", from: CGVector(dx: 0.97, dy: 0.5))
        click("intro.start")
        let row = waitFor("uninstaller.app.Alpha", timeout: 60)
        let rowFrame = row.frame, windowFrame = window.frame
        let rowPoint = CGVector(dx: (rowFrame.midX - windowFrame.minX) / windowFrame.width,
                                dy: (rowFrame.midY - windowFrame.minY) / windowFrame.height)
        XCTAssertFalse(drag("list-row", from: rowPoint), "Dragging a list row must not move the window")
        let button = waitFor("uninstaller.sort.1").frame
        XCTAssertFalse(drag("button", from: CGVector(dx: (button.midX - window.frame.minX) / window.frame.width,
                                                     dy: (button.midY - window.frame.minY) / window.frame.height)),
                       "Dragging a button must not move the window")
    }
}
