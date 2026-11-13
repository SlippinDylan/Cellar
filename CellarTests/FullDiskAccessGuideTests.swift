import XCTest
@testable import Cellar

@MainActor
final class FullDiskAccessGuideTests: XCTestCase {
    func testPermissionFlowUsesCurrentApplicationAndDoesNotStartUntilRequested() {
        let guide = FullDiskAccessGuide()
        XCTAssertEqual(guide.controller.droppedApps, [Bundle.main.bundleURL.standardizedFileURL])
        XCTAssertNil(guide.controller.currentPane)
        guide.close()
        XCTAssertNil(guide.controller.currentPane)
    }
}
