import AppKit
import XCTest
@testable import PermissionFlow

@MainActor
final class PermissionFlowLifecycleTests: XCTestCase {
    func testAuthorizationOpensOnceAndRemembersForegroundBeforeNavigation() {
        let fixture = PresentationFixture()
        let controller = fixture.makeController()
        fixture.events = []

        XCTAssertTrue(controller.authorize(pane: .fullDiskAccess))
        XCTAssertEqual(fixture.events, ["close", "foreground", "open", "show"])
        XCTAssertEqual(fixture.openedURLs, [PermissionFlowPane.fullDiskAccess.settingsURL])
        XCTAssertEqual(controller.currentPane, .fullDiskAccess)
        XCTAssertTrue(fixture.isTracking)
        XCTAssertTrue(fixture.isPanelVisible)

        controller.closePanel(returnToPreviousApp: true)
        XCTAssertEqual(fixture.returnedApplication?.bundleIdentifier, "fixture.Cellar")
        XCTAssertNil(controller.currentPane)
        XCTAssertFalse(fixture.isTracking)
        XCTAssertFalse(fixture.isPanelVisible)
    }

    func testFailedNavigationDoesNotPresentOrStartTracking() {
        let fixture = PresentationFixture()
        fixture.openSucceeds = false
        let controller = fixture.makeController()
        fixture.events = []

        XCTAssertFalse(controller.authorize(pane: .fullDiskAccess))
        XCTAssertEqual(fixture.events, ["close", "foreground", "open"])
        XCTAssertEqual(fixture.openedURLs.count, 1)
        XCTAssertNil(controller.currentPane)
        XCTAssertFalse(fixture.isTracking)
        XCTAssertFalse(fixture.isPanelVisible)
        controller.closePanel(returnToPreviousApp: true)
        XCTAssertNil(fixture.returnedApplication)
    }

    func testClosingIsIdempotentAndReleasesPresentation() {
        let fixture = PresentationFixture()
        let controller = fixture.makeController()
        XCTAssertTrue(controller.authorize(pane: .fullDiskAccess))
        fixture.events = []
        controller.closePanel()
        controller.closePanel(returnToPreviousApp: true)
        XCTAssertEqual(fixture.events, ["close", "close"])
        XCTAssertNil(fixture.returnedApplication)
        XCTAssertNil(controller.currentPane)
        XCTAssertFalse(fixture.isTracking)
        XCTAssertFalse(fixture.isPanelVisible)
    }

    func testStartingAnotherControllerClosesPreviousPresentation() {
        let firstFixture = PresentationFixture()
        let secondFixture = PresentationFixture()
        let first = firstFixture.makeController()
        let second = secondFixture.makeController()
        XCTAssertTrue(first.authorize(pane: .fullDiskAccess))
        XCTAssertTrue(second.authorize(pane: .fullDiskAccess))
        XCTAssertFalse(firstFixture.isTracking)
        XCTAssertFalse(firstFixture.isPanelVisible)
        XCTAssertNil(first.currentPane)
        XCTAssertTrue(secondFixture.isTracking)
        second.closePanel()
    }
}

@MainActor
final class SettingsWindowTrackerTests: XCTestCase {
    func testLosingAnAlreadyVisibleWindowStopsTrackingAndEndsTheGuideOnce() {
        var frame: CGRect? = CGRect(x: 100, y: 100, width: 700, height: 600)
        var probeCalls = 0
        var endings = 0
        let tracker = SettingsWindowTracker(frameProbe: { probeCalls += 1; return frame })
        tracker.onTrackingEnded = { endings += 1 }
        defer { tracker.stopTracking() }
        tracker.startTracking(promptIfNeeded: false)
        XCTAssertTrue(tracker.isTracking)
        XCTAssertEqual(tracker.currentFrame, frame)
        frame = nil
        for _ in 0..<11 { tracker.sampleWindow() }
        XCTAssertTrue(tracker.isTracking)
        XCTAssertEqual(endings, 0)
        tracker.sampleWindow()
        XCTAssertFalse(tracker.isTracking)
        XCTAssertNil(tracker.currentFrame)
        XCTAssertEqual(endings, 1)
        let stoppedCalls = probeCalls
        tracker.sampleWindow()
        XCTAssertEqual(probeCalls, stoppedCalls, "Queued samples cannot revive stopped tracking")
        XCTAssertEqual(endings, 1)
    }

    func testColdLaunchWaitsAndAReopenedSessionStartsWithCleanState() {
        var frame: CGRect?
        let tracker = SettingsWindowTracker(frameProbe: { frame })
        var endings = 0
        tracker.onTrackingEnded = { endings += 1 }
        defer { tracker.stopTracking() }
        tracker.startTracking(promptIfNeeded: false)
        for _ in 0..<30 { tracker.sampleWindow() }
        XCTAssertTrue(tracker.isTracking)
        XCTAssertNil(tracker.currentFrame)
        XCTAssertEqual(endings, 0)
        frame = CGRect(x: 100, y: 100, width: 700, height: 600)
        tracker.sampleWindow()
        XCTAssertEqual(tracker.currentFrame, frame)
        tracker.stopTracking()
        frame = nil
        tracker.startTracking(promptIfNeeded: false)
        for _ in 0..<30 { tracker.sampleWindow() }
        XCTAssertTrue(tracker.isTracking)
        XCTAssertEqual(endings, 0)
    }

    func testStartupTimeoutStopsTimerAndClearsTheGuideWithoutAWindow() {
        let start = ContinuousClock.now
        var now = start
        var probeCalls = 0
        var endings = 0
        let tracker = SettingsWindowTracker(frameProbe: { probeCalls += 1; return nil }, now: { now })
        tracker.onTrackingEnded = { endings += 1 }
        defer { tracker.stopTracking() }
        tracker.startTracking(promptIfNeeded: false)
        now = start.advanced(by: .milliseconds(9_999))
        tracker.sampleWindow()
        XCTAssertTrue(tracker.isTracking)
        XCTAssertEqual(endings, 0)
        now = start.advanced(by: .seconds(10))
        tracker.sampleWindow()
        XCTAssertFalse(tracker.isTracking)
        XCTAssertNil(tracker.currentFrame)
        XCTAssertEqual(endings, 1)
        let stoppedCalls = probeCalls
        tracker.sampleWindow()
        XCTAssertEqual(probeCalls, stoppedCalls)
        XCTAssertEqual(endings, 1)
    }

    func testSlowStartupCanSucceedAndReopenGetsFreshTenSeconds() {
        let start = ContinuousClock.now
        var now = start
        var frame: CGRect?
        var endings = 0
        let tracker = SettingsWindowTracker(frameProbe: { frame }, now: { now })
        tracker.onTrackingEnded = { endings += 1 }
        defer { tracker.stopTracking() }
        tracker.startTracking(promptIfNeeded: false)
        now = start.advanced(by: .milliseconds(9_900))
        frame = CGRect(x: 100, y: 100, width: 700, height: 600)
        tracker.sampleWindow()
        now = start.advanced(by: .seconds(100))
        tracker.sampleWindow()
        XCTAssertTrue(tracker.isTracking)
        XCTAssertEqual(tracker.currentFrame, frame)
        XCTAssertEqual(endings, 0)
        tracker.stopTracking()
        frame = nil
        tracker.startTracking(promptIfNeeded: false)
        now = start.advanced(by: .milliseconds(109_999))
        tracker.sampleWindow()
        XCTAssertTrue(tracker.isTracking)
        now = start.advanced(by: .seconds(110))
        tracker.sampleWindow()
        XCTAssertFalse(tracker.isTracking)
        XCTAssertEqual(endings, 1)
    }

    func testExplicitCloseClearsFrameAndPreventsFurtherProbeCalls() {
        var calls = 0
        let tracker = SettingsWindowTracker(frameProbe: {
            calls += 1
            return CGRect(x: 100, y: 100, width: 700, height: 600)
        })
        tracker.startTracking(promptIfNeeded: false)
        XCTAssertEqual(calls, 1)
        tracker.stopTracking()
        XCTAssertFalse(tracker.isTracking)
        XCTAssertNil(tracker.currentFrame)
        tracker.sampleWindow()
        XCTAssertEqual(calls, 1)
    }
}

final class SettingsWindowTrackingStateTests: XCTestCase {
    func testColdLaunchWaitsForTimeInsteadOfCountingMissingSamples() {
        let start = ContinuousClock.now
        var state = SettingsWindowTrackingState(missingWindowThreshold: 3)
        state.start(at: start)
        for _ in 0..<300 { XCTAssertFalse(state.observe(isVisible: false, at: start.advanced(by: .seconds(9)))) }
        XCTAssertFalse(state.observe(isVisible: true, at: start.advanced(by: .milliseconds(9_900))))
        XCTAssertFalse(state.observe(isVisible: true, at: start.advanced(by: .seconds(100))))
    }

    func testStartupEndsOnceAtTenSecondsWithoutAVisibleWindow() {
        let start = ContinuousClock.now
        var state = SettingsWindowTrackingState()
        state.start(at: start)
        XCTAssertFalse(state.observe(isVisible: false, at: start.advanced(by: .milliseconds(9_999))))
        XCTAssertTrue(state.observe(isVisible: false, at: start.advanced(by: .seconds(10))))
        XCTAssertFalse(state.observe(isVisible: false, at: start.advanced(by: .seconds(11))))
    }

    func testVisibleWindowDisappearingEndsAfterTheGracePeriod() {
        let start = ContinuousClock.now
        var state = SettingsWindowTrackingState(missingWindowThreshold: 3)
        state.start(at: start)
        XCTAssertFalse(state.observe(isVisible: true, at: start))
        XCTAssertFalse(state.observe(isVisible: false, at: start))
        XCTAssertFalse(state.observe(isVisible: false, at: start))
        XCTAssertTrue(state.observe(isVisible: false, at: start))
    }

    func testTemporaryWindowMissesDoNotAccumulateAcrossVisibleObservations() {
        let start = ContinuousClock.now
        var state = SettingsWindowTrackingState(missingWindowThreshold: 3)
        state.start(at: start)
        XCTAssertFalse(state.observe(isVisible: true, at: start))
        for _ in 0..<10 {
            XCTAssertFalse(state.observe(isVisible: false, at: start))
            XCTAssertFalse(state.observe(isVisible: false, at: start))
            XCTAssertFalse(state.observe(isVisible: true, at: start))
        }
    }

    func testReopenGetsANewStartupDeadlineAndForgetsPreviousVisibility() {
        let start = ContinuousClock.now
        var state = SettingsWindowTrackingState(missingWindowThreshold: 3)
        state.start(at: start)
        XCTAssertFalse(state.observe(isVisible: true, at: start))
        state.reset()
        let reopenedAt = start.advanced(by: .seconds(100))
        state.start(at: reopenedAt)
        for _ in 0..<30 { XCTAssertFalse(state.observe(isVisible: false, at: reopenedAt.advanced(by: .seconds(9)))) }
        XCTAssertTrue(state.observe(isVisible: false, at: reopenedAt.advanced(by: .seconds(10))))
    }
}

@MainActor
private final class PresentationFixture {
    var events: [String] = []
    var openedURLs: [URL] = []
    var openSucceeds = true
    var isTracking = false
    var isPanelVisible = false
    var returnedApplication: PermissionFlowController.ForegroundApplication?
    private var frontmost = PermissionFlowController.ForegroundApplication(
        processIdentifier: 42, bundleIdentifier: "fixture.Cellar"
    )

    func makeController() -> PermissionFlowController {
        PermissionFlowController(environment: .init(openSettings: { url in
            self.events.append("open")
            self.openedURLs.append(url)
            if self.openSucceeds {
                self.frontmost = .init(processIdentifier: 43, bundleIdentifier: "com.apple.systempreferences")
            }
            return self.openSucceeds
        }, frontmostApplication: {
            self.events.append("foreground")
            return self.frontmost
        }, activateApplication: { application in
            self.events.append("activate")
            self.returnedApplication = application
        }), presentation: .init(show: { _ in
            self.events.append("show")
            self.isTracking = true
            self.isPanelVisible = true
        }, close: { _ in
            self.events.append("close")
            self.isTracking = false
            self.isPanelVisible = false
        }))
    }
}
