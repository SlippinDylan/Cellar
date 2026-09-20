import XCTest
@testable import Cellar

final class ManagerSnapshotInstallerTests: XCTestCase {
    func testInstallsCompleteSnapshotIntoApplicationSupportRoot() async throws {
        let support = FileManager.default.temporaryDirectory
            .appending(path: "CellarSnapshotInstallerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: support) }

        let installer = ManagerSnapshotInstaller(
            bundle: Bundle.main,
            applicationSupportDirectory: support
        )
        let status = try await installer.installIfNeeded()

        XCTAssertEqual(status.version, ManagerSnapshotInstaller.snapshotVersion)
        XCTAssertTrue(status.nodeAvailable)
        XCTAssertTrue(status.homebrewAvailable)
        XCTAssertTrue(status.shellAvailable)
        XCTAssertTrue(status.location.hasPrefix(support.path))
    }
}
