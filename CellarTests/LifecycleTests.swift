import AppKit
import XCTest
@testable import Cellar

@MainActor
final class LifecycleTests: XCTestCase {
    func testTerminationIsAllowedWithoutActiveOperation() {
        XCTAssertEqual(
            AppTerminationPolicy.reply(hasActiveOperations: false),
            .terminateNow
        )
    }

    func testTerminationIsRefusedDuringActiveOperation() {
        XCTAssertEqual(
            AppTerminationPolicy.reply(hasActiveOperations: true),
            .terminateCancel
        )
    }

    func testAppDelegateReadsTheSharedOperationState() {
        let store = OperationStore.shared
        XCTAssertFalse(store.hasActiveOperations)
        let identifier = store.begin()

        XCTAssertEqual(
            AppDelegate().applicationShouldTerminate(NSApplication.shared),
            .terminateCancel
        )

        store.end(identifier)
        XCTAssertEqual(
            AppDelegate().applicationShouldTerminate(NSApplication.shared),
            .terminateNow
        )
    }
}
