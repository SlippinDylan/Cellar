import XCTest
@testable import Cellar

@MainActor
final class OnboardingStateTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "studio.slippindylan.Cellar.OnboardingStateTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testStepNavigationCoversAllFourStepsInOrder() {
        XCTAssertEqual(OnboardingStep.allCases, [.welcome, .coreTools, .environment, .complete])
        XCTAssertNil(OnboardingStep.welcome.previous)
        XCTAssertEqual(OnboardingStep.welcome.next, .coreTools)
        XCTAssertEqual(OnboardingStep.coreTools.previous, .welcome)
        XCTAssertEqual(OnboardingStep.coreTools.next, .environment)
        XCTAssertEqual(OnboardingStep.environment.previous, .coreTools)
        XCTAssertEqual(OnboardingStep.environment.next, .complete)
        XCTAssertEqual(OnboardingStep.complete.previous, .environment)
        XCTAssertNil(OnboardingStep.complete.next)
    }

    func testFreshStatePresentsOnLaunchOutsideTestsAndPersistsCompletion() {
        let state = OnboardingState(defaults: defaults, isRunningTests: false)
        XCTAssertFalse(state.isCompleted)
        XCTAssertTrue(state.shouldPresentOnLaunch)

        state.markCompleted()
        XCTAssertTrue(state.isCompleted)
        XCTAssertFalse(state.shouldPresentOnLaunch)

        let reloaded = OnboardingState(defaults: defaults, isRunningTests: false)
        XCTAssertTrue(reloaded.isCompleted)
        XCTAssertFalse(reloaded.shouldPresentOnLaunch)
    }

    func testHostedTestsNeverPresentOnboardingAutomatically() {
        let state = OnboardingState(defaults: defaults, isRunningTests: true)
        XCTAssertFalse(state.isCompleted)
        XCTAssertFalse(state.shouldPresentOnLaunch)
    }

    func testOnboardingSceneIdentifierIsDistinctFromMainWindow() {
        XCTAssertNotEqual(AppScene.onboardingWindowID, AppScene.mainWindowID)
    }

    func testRefreshPrerequisitesOnlyProbesLocalPrerequisitesWithoutOnlineCalls() async {
        final class Counter: @unchecked Sendable {
            var onlineCalls = 0
        }
        let counter = Counter()
        let dependencies = HomeDashboardDependencies(
            commandLineTools: { .installed(developerDirectory: "/Library/Developer/CommandLineTools") },
            homebrewLocationOccupied: { false },
            latestVersion: { _ in
                counter.onlineCalls += 1
                return "1.0.0"
            },
            requestCommandLineTools: {},
            openInstaller: {},
            finishInstallerHandoff: {}
        )
        let dashboard = HomeDashboardModel(dependencies: dependencies, operationStore: OperationStore())

        await dashboard.refreshPrerequisitesOnly(environment: [:])

        XCTAssertEqual(dashboard.commandLineTools, .available(.installed(developerDirectory: "/Library/Developer/CommandLineTools")))
        XCTAssertEqual(dashboard.homebrewLocationOccupied, false)
        XCTAssertEqual(counter.onlineCalls, 0)
    }

    func testWindowCloseCoordinatorInterceptsAndForwardsDelegateCalls() {
        final class MockDelegate: NSObject, NSWindowDelegate {
            var shouldCloseResult = true
            var didExposeCount = 0
            func windowShouldClose(_ sender: NSWindow) -> Bool { shouldCloseResult }
            func windowDidExpose(_ notification: Notification) { didExposeCount += 1 }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        let original = MockDelegate()
        window.delegate = original

        var allowsClose = false
        let coordinator = OnboardingWindowConfigurator.Coordinator { allowsClose }
        coordinator.configure(window: window)

        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertFalse(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.delegate === coordinator)

        XCTAssertFalse(coordinator.windowShouldClose(window))

        allowsClose = true
        XCTAssertTrue(coordinator.windowShouldClose(window))

        XCTAssertTrue(coordinator.responds(to: #selector(NSWindowDelegate.windowDidExpose(_:))))
        coordinator.teardown()
        XCTAssertTrue(window.delegate === original)
    }
}
