import XCTest

/// Launches the app inside a fresh `SandboxTree` and restores the user's own settings afterwards.
class MacWashingUITestCase: XCTestCase {
    static let defaultsDomain = "com.ovvi.MacWashing"

    var tree: SandboxTree!
    var app: XCUIApplication!
    private var savedDefaults: [String: Any]?

    override func setUpWithError() throws {
        continueAfterFailure = false
        savedDefaults = UserDefaults.standard.persistentDomain(forName: Self.defaultsDomain)
        tree = try SandboxTree()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        // The app persists sound, confirmations, removal modes and the like in its real defaults domain; put back what
        // the user had.
        if let savedDefaults {
            UserDefaults.standard.setPersistentDomain(savedDefaults, forName: Self.defaultsDomain)
        } else {
            UserDefaults.standard.removePersistentDomain(forName: Self.defaultsDomain)
        }
        tree.remove()
    }

    // MARK: Launching

    @discardableResult
    func launch(onboarded: Bool = true, confirm: Bool = true, exclusions: [String] = [],
                environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = tree.launchEnvironment.merging(environment) { _, extra in extra }
        app.launchArguments = [
            "-onboarded", onboarded ? "YES" : "NO",
            "-sound", "NO",
            "-confirm", confirm ? "YES" : "NO",
            "-junkRemoval", "delete",
            "-otherRemoval", "delete",
            "-diskHidden", "NO",
            "-diskLargeRows", "NO",
            "-exclusions", Self.plistArray(exclusions),
            "-AppleLanguages", "(ru)",
        ]
        app.launch()
        // The app starts without a Dock icon (LSUIElement) and asks to come forward itself; in a guest macOS may not let
        // it, so the runner brings it forward.
        if !app.wait(for: .runningForeground, timeout: 10) { app.activate() }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "App did not come to the foreground")
        self.app = app
        return app
    }

    /// Old-style property-list array for the argument domain (`("a", "b")`).
    static func plistArray(_ strings: [String]) -> String {
        "(" + strings.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }.joined(separator: ", ") + ")"
    }

    // MARK: Elements

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func elements(_ identifier: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: identifier)
    }

    /// The first element whose identifier ends with `suffix`.
    func element(identifierEndingWith suffix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier ENDSWITH %@", suffix)).firstMatch
    }

    func text(containing fragment: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    @discardableResult
    func waitFor(_ identifier: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let element = element(identifier)
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(identifier) did not appear", file: file, line: line)
        return element
    }

    func waitGone(_ identifier: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        let element = element(identifier)
        XCTAssertTrue(wait(timeout: timeout) { !element.exists }, "\(identifier) is still shown", file: file, line: line)
    }

    func waitForText(containing fragment: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(text(containing: fragment).waitForExistence(timeout: timeout), "No text containing «\(fragment)»", file: file, line: line)
    }

    /// Polls until `condition` holds.
    @discardableResult
    func wait(timeout: TimeInterval = 15, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    func click(_ identifier: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        let element = waitFor(identifier, timeout: timeout, file: file, line: line)
        XCTAssertTrue(element.isHittable, "\(identifier) is not hittable", file: file, line: line)
        element.click()
    }

    /// Accessibility value of a checkbox-like button: «выбрано», «частично», «не выбрано», «включено», «выключено».
    func value(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let element = waitFor(identifier, file: file, line: line)
        return element.value as? String ?? ""
    }

    func assertValue(_ identifier: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = waitFor(identifier, file: file, line: line)
        XCTAssertTrue(wait(timeout: 5) { (element.value as? String) == expected },
                      "\(identifier): expected «\(expected)», got «\(element.value as? String ?? "")»", file: file, line: line)
    }

    func assertLabel(_ identifier: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = waitFor(identifier, file: file, line: line)
        XCTAssertTrue(wait(timeout: 5) { element.label == expected },
                      "\(identifier): expected label «\(expected)», got «\(element.label)»", file: file, line: line)
    }

    func assertLabel(_ identifier: String, contains fragment: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = waitFor(identifier, file: file, line: line)
        XCTAssertTrue(wait(timeout: 5) { element.label.contains(fragment) },
                      "\(identifier): expected label containing «\(fragment)», got «\(element.label)»", file: file, line: line)
    }

    func typeInSearch(_ query: String) {
        let field = waitFor("search.field")
        field.click()
        field.typeText(query)
    }
}
