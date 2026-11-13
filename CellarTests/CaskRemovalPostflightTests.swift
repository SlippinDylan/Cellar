import XCTest
@testable import Cellar

final class CaskRemovalPostflightTests: XCTestCase {
    func testInterruptedAuthorizationKeepsCompletedPathsAndOnlyFailsRemainingPaths() throws {
        let root = CaskRemovalFileSystem.physicalURL(FileManager.default.temporaryDirectory)
            .appending(path: "CellarPostflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "already-removed")
        let second = root.appending(path: "remaining")
        try Data("remaining".utf8).write(to: second)
        let entries = [first, second].map {
            CaskRemovalEntry(path: $0.path, category: .cache, estimatedBytes: 1, disposition: .remove, fingerprint: "fixture")
        }
        let removal = CaskRemovalPlan(displayName: "Fixture", appURL: nil, entries: entries, warnings: [], ownershipFingerprint: "fixture")
        let error = CaskRemovalAuthorizationError.failed(status: 1, detail: "Authorization interrupted after first removal")
        let observed = CaskRemovalPostflight(removal: removal, failures: entries.map { .init(path: $0.path, error: error) }, installationRemoved: true)
        XCTAssertEqual(observed.paths.map(\.outcome), [.removed, .retained])
        XCTAssertEqual(observed.remaining.map(\.path), [second.path])
        XCTAssertEqual(observed.failures.map(\.path), [second.path])
        XCTAssertEqual(observed.failures.map(\.recoveryReason), [.authorizationFailed])
    }

    func testUnreadableAncestorIsUnverifiedAndDoesNotFollowTheLink() throws {
        let root = CaskRemovalFileSystem.physicalURL(FileManager.default.temporaryDirectory)
            .appending(path: "CellarPostflight-\(UUID().uuidString)")
        let target = root.appending(path: "target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let path = link.appending(path: "unknown").path
        let entry = CaskRemovalEntry(path: path, category: .cache, estimatedBytes: nil, disposition: .remove, fingerprint: "fixture")
        let removal = CaskRemovalPlan(displayName: "Fixture", appURL: nil, entries: [entry], warnings: [], ownershipFingerprint: "fixture")
        let observed = CaskRemovalPostflight(removal: removal, failures: [], installationRemoved: true)
        XCTAssertEqual(observed.paths.map(\.outcome), [.unverified])
        XCTAssertEqual(observed.remaining.map(\.path), [path])
        XCTAssertEqual(observed.failures.map(\.path), [path])
        XCTAssertTrue(CaskRemovalFileSystem.exists(path), "Deletion guards must continue to treat unreadable paths conservatively")
    }

    func testProtectedPathNeverBecomesACellarDeletionSuccess() {
        let entry = CaskRemovalEntry(path: "/nonexistent-cellar-protected-fixture-\(UUID().uuidString)", category: .applicationData,
                                     estimatedBytes: nil, disposition: .protected, fingerprint: "fixture")
        let removal = CaskRemovalPlan(displayName: "Fixture", appURL: nil, entries: [entry], warnings: [], ownershipFingerprint: "fixture")
        let observed = CaskRemovalPostflight(removal: removal, failures: [], installationRemoved: true)
        XCTAssertEqual(observed.paths.map(\.outcome), [.retained])
        XCTAssertTrue(observed.remaining.isEmpty)
        XCTAssertTrue(observed.failures.isEmpty)
    }

    func testAbsentPathCannotConfirmRemovalWhenInstallationStateIsUnknown() {
        let root = CaskRemovalFileSystem.physicalURL(FileManager.default.temporaryDirectory)
        let entry = CaskRemovalEntry(path: root.appending(path: "CellarAbsent-\(UUID().uuidString)").path,
            category: .application, estimatedBytes: nil, disposition: .homebrew, fingerprint: "fixture")
        let removal = CaskRemovalPlan(displayName: "Fixture", appURL: nil, entries: [entry], warnings: [], ownershipFingerprint: "fixture")
        let observed = CaskRemovalPostflight(removal: removal, failures: [], installationRemoved: false)
        XCTAssertEqual(observed.paths.map(\.outcome), [.unverified])
    }
}
