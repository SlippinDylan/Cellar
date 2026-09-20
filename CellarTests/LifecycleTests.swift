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

    func testBusyStateCoversEveryModule() {
        let model = AppModel.live()

        XCTAssertFalse(model.isBusy)
        model.isHomebrewWorking = true
        XCTAssertTrue(model.isBusy)
        model.isHomebrewWorking = false
        model.isNodeWorking = true
        XCTAssertTrue(model.isBusy)
        model.isNodeWorking = false
        model.isShellWorking = true
        XCTAssertTrue(model.isBusy)
    }

    func testHomebrewExecutionWaitsForAnotherModule() async {
        let model = AppModel.live()
        let plan = HomebrewActionPlan(
            id: UUID(),
            action: .update,
            targets: [],
            tapName: nil,
            dependencies: [],
            dependents: [],
            artifacts: [],
            residualPaths: [],
            associatedPackages: [],
            generatedAt: Date(),
            stateFingerprint: nil
        )
        model.homebrewPlan = plan
        model.isNodeWorking = true

        await model.executeHomebrewPlan()

        XCTAssertEqual(model.homebrewPlan?.id, plan.id)
        XCTAssertFalse(model.isHomebrewWorking)
    }
}
