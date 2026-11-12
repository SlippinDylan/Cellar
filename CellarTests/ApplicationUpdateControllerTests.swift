import Combine
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

    func testUpdaterAvailabilityPublishesEveryTransitionWithoutStartingUpdater() {
        let controller = ApplicationUpdateController(updaterEnabled: false)
        let availability = CurrentValueSubject<Bool, Never>(false)
        controller.observeUpdateAvailability(availability)
        var received: [Bool] = []
        var invalidations = 0
        let values = controller.$canCheckForUpdates.sink { received.append($0) }
        let changes = controller.objectWillChange.sink { invalidations += 1 }

        availability.send(true)
        XCTAssertTrue(controller.canCheckForUpdates)
        availability.send(false)
        XCTAssertFalse(controller.canCheckForUpdates)
        XCTAssertEqual(received, [false, true, false])
        XCTAssertEqual(invalidations, 2)
        withExtendedLifetime((values, changes)) {}
    }

    func testAvailabilityUsesTheCurrentStateWhenObservationStarts() {
        let controller = ApplicationUpdateController(updaterEnabled: false)
        let availability = CurrentValueSubject<Bool, Never>(true)
        controller.observeUpdateAvailability(availability)
        XCTAssertTrue(controller.canCheckForUpdates)
    }
}
