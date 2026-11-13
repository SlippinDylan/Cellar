import Darwin
import XCTest
@testable import Cellar

@MainActor
final class ProtectedFileAccessTests: XCTestCase {
    func testDirectoryVerificationDoesNotNeedToReadFiles() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(ProtectedFileAccessVerification.readResult(directory: root), .verified)
        let file = root.appending(path: "private-data")
        try Data([1]).write(to: file)
        XCTAssertEqual(chmod(file.path, 0), 0)
        defer { chmod(file.path, 0o600) }
        XCTAssertEqual(ProtectedFileAccessVerification.readResult(directory: root), .verified)
    }

    func testDeniedMissingAndSymlinkPathsNeverVerify() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "protected")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(directory.path, 0), 0)
        XCTAssertEqual(ProtectedFileAccessVerification.readResult(directory: directory), .denied)
        XCTAssertEqual(chmod(directory.path, 0o700), 0)
        let alias = root.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        XCTAssertEqual(ProtectedFileAccessVerification.readResult(directory: alias), .unavailable)
        XCTAssertEqual(ProtectedFileAccessVerification.readResult(directory: alias.appending(path: "child")), .unavailable)
        XCTAssertEqual(ProtectedFileAccessVerification.readResult(directory: root.appending(path: "missing")), .unavailable)
    }

    func testRefreshClearsEarlierVerifiedAccessWhenAccessChanges() async {
        let checker = AccessSequence()
        let model = ProtectedFileAccessVerification(checkAccess: { await checker.next() })
        await model.refresh()
        XCTAssertTrue(model.isVerified)
        await model.refresh()
        XCTAssertEqual(model.result, .denied)
        XCTAssertFalse(model.isVerified)
        await model.refresh()
        XCTAssertEqual(model.result, .unavailable)
        XCTAssertFalse(model.isVerified)
    }

    func testLateResultCannotReplaceNewerDenial() async {
        let started = expectation(description: "First verification started")
        let checker = PausedAccessCheck(started: { started.fulfill() })
        let model = ProtectedFileAccessVerification(checkAccess: { await checker.next() })
        let first = Task { await model.refresh() }
        await fulfillment(of: [started], timeout: 3)
        await model.refresh()
        XCTAssertEqual(model.result, .denied)
        await checker.release()
        await first.value
        XCTAssertEqual(model.result, .denied)
    }

    func testLeavingSettingsDiscardsLateVerification() async {
        let started = expectation(description: "Verification started")
        let checker = PausedAccessCheck(started: { started.fulfill() })
        let model = ProtectedFileAccessVerification(checkAccess: { await checker.next() })
        let refresh = Task { await model.refresh() }
        await fulfillment(of: [started], timeout: 3)
        model.invalidate()
        await checker.release()
        await refresh.value
        XCTAssertNil(model.result)
        XCTAssertFalse(model.isVerified)
    }

    private func fixtureDirectory() throws -> URL {
        let root = CaskRemovalFileSystem.physicalURL(FileManager.default.temporaryDirectory)
            .appending(path: "CellarAccessVerification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private actor AccessSequence {
    var results: [ProtectedFileAccessResult] = [.verified, .denied, .unavailable]
    func next() -> ProtectedFileAccessResult { results.removeFirst() }
}

private actor PausedAccessCheck {
    let started: @Sendable () -> Void
    let gate: AsyncStream<Void>
    let continuation: AsyncStream<Void>.Continuation
    var didStart = false

    init(started: @escaping @Sendable () -> Void) {
        self.started = started
        (gate, continuation) = AsyncStream<Void>.makeStream()
    }

    func next() async -> ProtectedFileAccessResult {
        if didStart { return .denied }
        didStart = true
        started()
        for await _ in gate { break }
        return .verified
    }

    func release() { continuation.yield(); continuation.finish() }
}
