import XCTest
@testable import Cellar

@MainActor
final class ActivityStoreTests: XCTestCase {
    func testHomebrewNonPackageScopesAcceptOnlySemanticTargets() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActivityStore(applicationSupportRoot: root)
        for name in ["newco/apps", "owner/tools+extra"] {
            store.append(.init(id: UUID(), operation: .addHomebrewTap, scope: .homebrewTaps, targetDisplayNames: [name], date: Date(), status: .succeeded,
                               itemOutcomes: [.init(displayName: name, status: .succeeded, reason: nil)]))
        }
        let safe = store.summaries
        for name in ["/Users/private/tap", "../repo", "owner/..", "owner/repo/file", "https://user:password@example.com", "TOKEN=secret", "owner/with space", "-option/repo"] {
            XCTAssertThrowsError(try store.record(.init(id: UUID(), operation: .addHomebrewTap, scope: .homebrewTaps, targetDisplayNames: [name], date: Date(), status: .failed, itemOutcomes: [])))
        }
        for scope in [ActivityScope.homebrewMetadata, .homebrewDiagnostics] {
            XCTAssertThrowsError(try store.record(.init(id: UUID(), operation: .maintenance, scope: scope, targetDisplayNames: ["/private/path"], date: Date(), status: .succeeded, itemOutcomes: [])))
        }
        XCTAssertEqual(store.summaries, safe)
    }

    func testRepeatedFailedWritesKeepBoundedUniqueLiveRecordsAndPersistTogetherOnSuccess() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActivityStore(applicationSupportRoot: root)
        let first = summary(date: Date(timeIntervalSince1970: 1))
        store.append(first)
        let original = try Data(contentsOf: store.fileURL)
        let directory = store.fileURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let second = summary(date: Date(timeIntervalSince1970: 2))
        let third = summary(date: Date(timeIntervalSince1970: 3))
        store.append(second)
        store.append(third)
        XCTAssertEqual(store.summaries.map(\.id), [third.id, second.id, first.id])
        let replaced = ActivitySummary(id: second.id, operation: second.operation, scope: second.scope, targetDisplayNames: second.targetDisplayNames,
                                       date: Date(timeIntervalSince1970: 4), status: .succeeded, itemOutcomes: [])
        store.append(replaced)
        store.retrySaving()
        XCTAssertEqual(store.summaries.map(\.id), [second.id, third.id, first.id])
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        XCTAssertEqual(store.persistenceError, .writeFailed)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let fourth = summary(date: Date(timeIntervalSince1970: 5))
        store.append(fourth)
        XCTAssertNil(store.persistenceError)
        let restored = ActivityStore(applicationSupportRoot: root)
        restored.restore()
        XCTAssertEqual(restored.summaries, store.summaries)
        XCTAssertEqual(restored.summaries.map(\.id), [fourth.id, second.id, third.id, first.id])
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        for index in 6..<111 { store.append(summary(date: Date(timeIntervalSince1970: Double(index)))) }
        XCTAssertEqual(store.summaries.count, 100)
        XCTAssertEqual(store.summaries.first?.date, Date(timeIntervalSince1970: 110))
        XCTAssertEqual(store.summaries.last?.date, Date(timeIntervalSince1970: 11))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        store.retrySaving()
        restored.retryLoading()
        XCTAssertEqual(restored.summaries, store.summaries)
        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        for raw in ["command", "stdout", "stderr", "registry", "/Users", "TOKEN"] { XCTAssertFalse(json.contains(raw), raw) }
    }

    func testRestoreOnceTerminalOnlyAndStableUpdates() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActivityStore(applicationSupportRoot: root)
        let first = summary()
        try store.record(first)
        store.restore()
        try Data("corrupt".utf8).write(to: store.fileURL)
        store.restore()
        XCTAssertEqual(store.summaries, [first])
        XCTAssertNil(store.persistenceError)
        let replacement = ActivitySummary(id: first.id, operation: first.operation, scope: first.scope, targetDisplayNames: first.targetDisplayNames,
                                          date: first.date, status: .succeeded, itemOutcomes: [])
        try store.record(replacement)
        XCTAssertEqual(store.summaries, [replacement])
        let started = ActivitySummary(id: UUID(), operation: .refresh, scope: nil, targetDisplayNames: [], date: Date(), status: .running, itemOutcomes: [])
        XCTAssertThrowsError(try store.record(started))
    }

    func testIsolationFailureDoesNotOverwriteOriginalAndCanRecover() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActivityStore(applicationSupportRoot: root)
        try store.record(summary())
        let original = Data("corrupt original".utf8)
        try original.write(to: store.fileURL)
        let directory = store.fileURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        store.restore()
        XCTAssertEqual(store.persistenceError, .isolationFailed)
        store.append(summary())
        XCTAssertEqual(store.persistenceError, .isolationFailed)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        store.retryLoading()
        XCTAssertEqual(store.persistenceError, .corruptData)
        store.append(summary())
        XCTAssertNil(store.persistenceError)
        XCTAssertEqual(store.summaries.count, 1)
    }

    func testFailedSaveCanRetryAndKeepsSemanticReason() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActivityStore(applicationSupportRoot: root)
        try store.record(summary())
        let directory = store.fileURL.deletingLastPathComponent()
        let failed = ActivitySummary(id: UUID(), operation: .configuration, scope: .npm(.init(identifier: "/private", nodeVersion: "v22.0.0", npmVersion: "10.0.0")),
                                     targetDisplayNames: [], date: Date(), status: .failed, itemOutcomes: [], reason: .stateChanged)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        store.append(failed)
        XCTAssertEqual(store.persistenceError, .writeFailed)
        XCTAssertEqual(store.summaries.count, 2)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        store.retrySaving()
        XCTAssertNil(store.persistenceError)
        let restored = ActivityStore(applicationSupportRoot: root)
        restored.restore()
        XCTAssertEqual(restored.summaries.first?.reason, .stateChanged)
        XCTAssertEqual(restored.summaries.count, 2)
    }

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
        XCTAssertEqual(failingStore.summaries.count, 1)
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
        let attempted = summary(date: Date(timeIntervalSince1970: 200))
        XCTAssertThrowsError(try store.record(attempted)) { error in
            XCTAssertEqual(error as? ActivityStoreError, .writeFailed)
        }
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        XCTAssertEqual(store.summaries, [attempted, first])
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
