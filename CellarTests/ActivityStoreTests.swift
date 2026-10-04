import XCTest
@testable import Cellar

@MainActor
final class ActivityStoreTests: XCTestCase {
    func testShellSemanticStepsRoundTripAndRejectUserControlledNames() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActivityStore(applicationSupportRoot: root)
        let result = ShellConfigurationResult(operations: [], failure: "private raw diagnostic", stepOutcomes: [.init(step: .plugins, status: .succeeded), .init(step: .theme, status: .failed)])
        try store.record(result.activitySummary())
        let restored = ActivityStore(applicationSupportRoot: root)
        try restored.load()
        XCTAssertEqual(restored.summaries, store.summaries)
        XCTAssertEqual(restored.summaries.first?.itemOutcomes.compactMap(\.shellStep), [.plugins, .theme])
        XCTAssertEqual(restored.summaries.first?.status, .partiallySucceeded)
        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertFalse(json.contains("private raw diagnostic"))
        let unsafe = ActivitySummary(id: UUID(), operation: .configuration, scope: .shell, targetDisplayNames: ["user-plugin"], date: Date(), status: .failed, itemOutcomes: [])
        XCTAssertThrowsError(try store.record(unsafe))
        let unsafeStep = ActivitySummary(id: UUID(), operation: .configuration, scope: .shell, targetDisplayNames: [], date: Date(), status: .failed,
                                        itemOutcomes: [.init(displayName: "/Users/private/plugin", status: .failed, reason: .providerFailure, shellStep: .plugins)])
        XCTAssertThrowsError(try store.record(unsafeStep))
    }

    func testShellCancelledAndPartialStepsRemainDistinct() throws {
        let cancelled = ShellConfigurationResult(operations: [], failure: "cancelled", wasCancelled: true,
                                                 stepOutcomes: [.init(step: .plugins, status: .cancelled), .init(step: .theme, status: .cancelled)])
        XCTAssertEqual(cancelled.activitySummary().status, .cancelled)
        XCTAssertEqual(cancelled.activitySummary().itemOutcomes.map(\.status), [.cancelled, .cancelled])
        let partial = ShellConfigurationResult(operations: [], failure: "cancelled", wasCancelled: true,
                                               stepOutcomes: [.init(step: .plugins, status: .succeeded), .init(step: .theme, status: .cancelled)])
        XCTAssertEqual(partial.activitySummary().status, .partiallySucceeded)
        XCTAssertEqual(partial.activitySummary().itemOutcomes.map(\.status), [.succeeded, .cancelled])
    }

    func testVersionOneActivityLoadsWithoutShellSteps() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActivityStore(applicationSupportRoot: root)
        try store.record(summary())
        let data = try Data(contentsOf: store.fileURL)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["schemaVersion"] = 1
        try JSONSerialization.data(withJSONObject: json).write(to: store.fileURL)
        let restored = ActivityStore(applicationSupportRoot: root)
        try restored.load()
        XCTAssertEqual(restored.summaries, store.summaries)
        XCTAssertTrue(restored.summaries.flatMap(\.itemOutcomes).allSatisfy { $0.shellStep == nil })
        XCTAssertEqual(PersistedActivityEnvelope.currentSchemaVersion, 2)
    }

    func testRoundTripAndNewestHundredOnly() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActivityStore(applicationSupportRoot: root)
        for index in 0..<105 { try store.record(summary(date: Date(timeIntervalSince1970: Double(index)))) }

        let restored = ActivityStore(applicationSupportRoot: root)
        try restored.load()

        XCTAssertEqual(restored.summaries, store.summaries)
        XCTAssertEqual(restored.summaries.count, 100)
        XCTAssertEqual(restored.summaries.first?.date, Date(timeIntervalSince1970: 104))
        XCTAssertEqual(restored.summaries.last?.date, Date(timeIntervalSince1970: 5))
    }

    func testSanitizationRemovesEnvironmentIdentifierPathAndExcludesRawDiagnostics() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActivityStore(applicationSupportRoot: root)
        try store.record(summary(environment: .init(
            identifier: "/Users/private/.nvm?TOKEN=secret", nodeVersion: "v22.0.0", npmVersion: "10.0.0"
        )))
        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertTrue(json.contains("nvm:v22.0.0"))
        for raw in ["/Users", "TOKEN", "secret", "command", "stdout", "stderr", "userFacingMessage", "registry", "logFile"] {
            XCTAssertFalse(json.contains(raw), raw)
        }
        for unsafe in ["/Users/private/package", "Users/private/package", "https://user:secret@example.com", "TOKEN=secret", "npm install foo", "../../private"] {
            XCTAssertThrowsError(try store.record(summary(names: [unsafe]))) { error in
                XCTAssertEqual(error as? ActivityStoreError, .invalidSummary)
            }
        }
        XCTAssertEqual(store.summaries.count, 1)
    }

    func testCorruptAndUnsupportedFilesAreIsolatedAndReported() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActivityStore(applicationSupportRoot: root)
        try store.record(summary())
        try Data("broken TOKEN=secret".utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? ActivityStoreError, .corruptData)
        }
        XCTAssertTrue(store.summaries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.fileURL.deletingLastPathComponent().path)
            .filter { $0.hasSuffix(".isolated") }.count, 1)
        try store.record(summary())
        try Data(#"{"schemaVersion":99,"summaries":[]}"#.utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? ActivityStoreError, .unsupportedSchema(99))
        }
        XCTAssertTrue(store.summaries.isEmpty)
        try store.record(summary())
        XCTAssertEqual(store.summaries.count, 1)
    }

    func testInvalidDataIsRejectedOnLoadAndOversizedFileIsBounded() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActivityStore(applicationSupportRoot: root)
        try store.record(summary())
        try JSONEncoder().encode(PersistedActivityEnvelope(summaries: [summary(names: ["/Users/private"])]))
            .write(to: store.fileURL)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? ActivityStoreError, .corruptData)
        }
        try store.record(summary())
        try Data(repeating: 32, count: ActivityStore.maximumFileBytes + 1).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? ActivityStoreError, .corruptData)
        }
        XCTAssertTrue(store.summaries.isEmpty)
    }

    func testFailedWriteKeepsPriorFileAndMemoryAndUsesNoJournal() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActivityStore(applicationSupportRoot: root)
        let first = summary()
        try store.record(first)
        let original = try Data(contentsOf: store.fileURL)
        XCTAssertThrowsError(try store.record(summary(names: ["secret=bad"])))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        XCTAssertEqual(store.summaries, [first])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.fileURL.deletingLastPathComponent().path), ["activity.json"])
        let blocked = root.appending(path: "blocked")
        try Data().write(to: blocked)
        let failingStore = ActivityStore(applicationSupportRoot: blocked)
        XCTAssertThrowsError(try failingStore.record(summary())) { error in
            XCTAssertEqual(error as? ActivityStoreError, .writeFailed)
        }
        XCTAssertTrue(failingStore.summaries.isEmpty)
    }

    func testMissingFileDoesNotCreateRuntimeDirectoryAndLegacyEntryIsNotMigrated() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActivityStore(applicationSupportRoot: root)
        try store.load()
        XCTAssertTrue(store.summaries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Cellar").path))
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"[{"title":"legacy rendered message","detail":"TOKEN=legacy-secret stdout","command":"npm install"}]"#.utf8)
            .write(to: store.fileURL)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? ActivityStoreError, .corruptData)
        }
        XCTAssertTrue(store.summaries.isEmpty)
        try store.record(summary())
        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertFalse(json.contains("legacy"))
        XCTAssertFalse(json.contains("stdout"))
        XCTAssertFalse(json.contains("command"))
    }

    func testUnsupportedVersionIsIdentifiedBeforeDecodingFuturePayload() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActivityStore(applicationSupportRoot: root)
        try store.record(summary())
        try Data(#"{"schemaVersion":99,"futurePayload":{}}"#.utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? ActivityStoreError, .unsupportedSchema(99))
        }
    }

    func testVersionedHomebrewNameIsSafeAndVersionsCannotCarryArbitraryMetadata() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActivityStore(applicationSupportRoot: root)
        let formula = ActivitySummary(id: UUID(), operation: .update, scope: .homebrew(.formula),
                                      targetDisplayNames: ["python@3.13"], date: Date(), status: .succeeded,
                                      itemOutcomes: [.init(displayName: "python@3.13", status: .succeeded, reason: nil)])
        try store.record(formula)
        XCTAssertEqual(store.summaries.first, formula)
        XCTAssertThrowsError(try store.record(summary(environment: .init(
            identifier: "opaque", nodeVersion: "v22.0.0+credential", npmVersion: "10.0.0"
        )))) { error in
            XCTAssertEqual(error as? ActivityStoreError, .invalidSummary)
        }
    }

    func testAtomicWriteFailurePreservesExistingFile() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActivityStore(applicationSupportRoot: root)
        let first = summary()
        try store.record(first)
        let original = try Data(contentsOf: store.fileURL)
        let directory = store.fileURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        XCTAssertThrowsError(try store.record(summary(date: Date(timeIntervalSince1970: 200)))) { error in
            XCTAssertEqual(error as? ActivityStoreError, .writeFailed)
        }
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        XCTAssertEqual(store.summaries, [first])
    }

    func testFailureIsObservableWithoutBlockingEnvironmentWork() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActivityStore(applicationSupportRoot: root)
        store.append(summary(names: ["TOKEN=secret"]))
        XCTAssertEqual(store.persistenceError, .invalidSummary)
        store.append(summary())
        XCTAssertNil(store.persistenceError)
        try Data("corrupt".utf8).write(to: store.fileURL)
        store.restore()
        XCTAssertEqual(store.persistenceError, .corruptData)
        XCTAssertTrue(store.summaries.isEmpty)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarActivityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func summary(date: Date = Date(timeIntervalSince1970: 100), names: [String] = ["@scope/package"],
                         environment: NodeEnvironmentContext = .init(identifier: "nvm:v22.0.0", nodeVersion: "v22.0.0", npmVersion: "10.0.0")) -> ActivitySummary {
        ActivitySummary(id: UUID(), operation: .install, scope: .npm(environment), targetDisplayNames: names,
                        date: date, status: .failed, itemOutcomes: names.map {
            .init(displayName: $0, status: .failed, reason: .providerFailure)
        })
    }
}
