import XCTest

final class OmleteUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Port 9 answers nothing, so this is the app with no signal: Home must
    /// still come up and offer New list.
    @MainActor
    func testHomeComesUpWithNoSignal() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-apiBaseURL", "http://127.0.0.1:9"]
        app.launch()

        XCTAssertTrue(app.buttons["home.newListButton"].waitForExistence(timeout: 10))
    }
}
