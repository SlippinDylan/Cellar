import XCTest
@testable import Cellar

@MainActor
final class ApplicationUpdateControllerTests: XCTestCase {
    func testUpdateChannelHierarchy() {
        XCTAssertEqual(ApplicationUpdateController.allowedChannels(for: "stable"), [])
        XCTAssertEqual(ApplicationUpdateController.allowedChannels(for: "beta"), ["beta"])
        XCTAssertEqual(ApplicationUpdateController.allowedChannels(for: "alpha"), ["alpha", "beta"])
    }

    func testDisabledControllerCannotCheckForUpdates() {
        let controller = ApplicationUpdateController(updaterEnabled: false)
        XCTAssertFalse(controller.canCheckForUpdates)
    }
}
