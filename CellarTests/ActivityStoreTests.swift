import XCTest
@testable import Cellar

@MainActor
final class ActivityStoreTests: XCTestCase {
    func testResultsAreSessionOnlyAndLegacyHistoryRemainsUntouched() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appending(path: "Cellar/Activity/activity.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("legacy history must remain untouched".utf8)
        try original.write(to: legacy)
        let store = ActivityStore()
        try store.record(summary())
        XCTAssertEqual(store.summaries.count, 1)
        XCTAssertTrue(ActivityStore().summaries.isEmpty)
        XCTAssertNil(ActivityStore().latestResult)
        XCTAssertEqual(try Data(contentsOf: legacy), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: legacy.deletingLastPathComponent().path), ["activity.json"])
    }

    func testSessionSummariesStayBoundedUniqueAndLatestResultSurvivesRefresh() throws {
        let store = ActivityStore()
        for index in 0..<105 { try store.record(summary(date: Date(timeIntervalSince1970: Double(index)))) }
        XCTAssertEqual(store.summaries.count, 100)
        let first = try XCTUnwrap(store.summaries.first)
        try store.record(first)
        XCTAssertEqual(store.summaries.count, 100)
        XCTAssertEqual(store.summaries.first, first)
        XCTAssertEqual(store.latestResult, first)
        try store.record(.init(id: UUID(), operation: .refresh, scope: nil, targetDisplayNames: [], date: Date(), status: .failed, itemOutcomes: [], reason: .network))
        XCTAssertEqual(store.latestResult, first)
        store.dismissResult()
        XCTAssertNil(store.latestResult)
        XCTAssertFalse(store.summaries.isEmpty)
    }

    func testSearchUsesPageFeedbackAndPreservesPreviousTaskResult() throws {
        XCTAssertFalse(ActivityOperationKind.search.showsTaskFeedback)
        XCTAssertFalse(ActivityOperationKind.refresh.showsTaskFeedback)
        XCTAssertTrue(ActivityOperationKind.install.showsTaskFeedback)
        let store = ActivityStore()
        let previous = summary()
        try store.record(previous)
        try store.record(.init(id: UUID(), operation: .search, scope: nil, targetDisplayNames: [], date: Date(), status: .succeeded, itemOutcomes: []))
        XCTAssertEqual(store.latestResult, previous)
        XCTAssertNil(store.verificationWarning)
    }

    func testInvalidResultDoesNotReplaceValidFeedbackAndFailureIsObservable() throws {
        let store = ActivityStore()
        let valid = summary()
        store.append(valid)
        store.append(summary(names: ["TOKEN=secret"]))
        XCTAssertEqual(store.validationError, .invalidSummary)
        XCTAssertEqual(store.latestResult, valid)
        XCTAssertEqual(store.summaries, [valid])
        store.append(valid)
        XCTAssertNil(store.validationError)
        let running = ActivitySummary(id: UUID(), operation: .install, scope: .homebrew(.formula), targetDisplayNames: ["git"], date: Date(), status: .running, itemOutcomes: [])
        XCTAssertThrowsError(try store.record(running))
    }

    func testSanitizerRejectsUnsafePackageNamesAndRemovesInstallationPaths() throws {
        let store = ActivityStore()
        try store.record(summary(environment: .init(identifier: "/Users/private/.nvm", nodeVersion: "v22.0.0", npmVersion: "10.0.0")))
        let json = String(decoding: try JSONEncoder().encode(store.summaries), as: UTF8.self)
        XCTAssertFalse(json.contains("/Users/private"))
        for unsafe in ["/Users/private", "TOKEN=secret", "../package", "--help", "bad\nname"] {
            XCTAssertThrowsError(try store.record(summary(names: [unsafe])))
        }
        XCTAssertThrowsError(try store.record(summary(environment: .init(identifier: "opaque", nodeVersion: "v22.0.0+credential", npmVersion: "10.0.0"))))
        let formula = ActivitySummary(id: UUID(), operation: .update, scope: .homebrew(.formula), targetDisplayNames: ["python@3.13"], date: Date(), status: .succeeded, itemOutcomes: [])
        try store.record(formula)
        XCTAssertEqual(store.latestResult, formula)
    }

    func testShellResultsRetainSemanticStepsWithoutUserControlledNames() throws {
        let store = ActivityStore()
        let result = ShellConfigurationResult(operations: [], failure: "private raw diagnostic", stepOutcomes: [.init(step: .plugins, status: .succeeded), .init(step: .theme, status: .failed)])
        try store.record(result.activitySummary())
        XCTAssertEqual(store.latestResult?.itemOutcomes.compactMap(\.shellStep), [.plugins, .theme])
        XCTAssertEqual(store.latestResult?.status, .partiallySucceeded)
        let json = String(decoding: try JSONEncoder().encode(store.summaries), as: UTF8.self)
        XCTAssertFalse(json.contains("private raw diagnostic"))
        let unsafe = ActivitySummary(id: UUID(), operation: .configuration, scope: .shell, targetDisplayNames: ["user-plugin"], date: Date(), status: .failed, itemOutcomes: [])
        XCTAssertThrowsError(try store.record(unsafe))
        let unsafeStep = ActivitySummary(id: UUID(), operation: .configuration, scope: .shell, targetDisplayNames: [], date: Date(), status: .failed,
                                        itemOutcomes: [.init(displayName: "/Users/private/plugin", status: .failed, reason: .providerFailure, shellStep: .plugins)])
        XCTAssertThrowsError(try store.record(unsafeStep))
    }

    func testPartialResultsLogEveryItemAndRemainVisibleWhenLevelFiltersSummary() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "CellarTaskLogging-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let logger = FileLogStore(directory: root, defaults: defaults)
        let store = ActivityStore(logStore: logger)
        let partial = ActivitySummary(id: UUID(), operation: .install, scope: .homebrew(.formula), targetDisplayNames: ["one", "two"], date: Date(), status: .partiallySucceeded, itemOutcomes: [
            .init(displayName: "one", status: .succeeded, reason: nil), .init(displayName: "two", status: .failed, reason: .providerFailure)
        ])
        store.append(partial)
        await logger.flush()
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "log" }
        var text = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(text.contains("status=partiallySucceeded"))
        XCTAssertTrue(text.contains("target=one status=succeeded"))
        XCTAssertTrue(text.contains("target=two status=failed"))
        XCTAssertTrue(text.contains(partial.id.uuidString))
        logger.minimumLevel = .critical
        let filtered = summary()
        store.append(filtered)
        await logger.flush()
        text = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertFalse(text.contains(filtered.id.uuidString))
        XCTAssertEqual(store.latestResult, filtered)
    }

    func testFileFailureDoesNotLoseCurrentTaskResult() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appending(path: "blocked")
        try Data().write(to: blocked)
        let suite = "CellarTaskLoggingFailure-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let logger = FileLogStore(directory: blocked, defaults: defaults)
        let store = ActivityStore(logStore: logger)
        let result = summary()
        store.append(result)
        await logger.flush()
        XCTAssertNotNil(logger.errorMessage)
        XCTAssertEqual(store.latestResult, result)
        XCTAssertNil(store.validationError)
    }

    func testVerificationFailureRemainsVisibleWithoutReplacingItemOutcomes() throws {
        let store = ActivityStore()
        let result = summary()
        try store.record(result)
        try store.record(.init(id: UUID(), operation: .refresh, scope: result.scope, targetDisplayNames: [], date: Date(),
                               status: .failed, itemOutcomes: [], reason: .stateUnavailable))
        XCTAssertEqual(store.latestResult, result)
        XCTAssertEqual(store.verificationWarning, .stateUnavailable)
        store.dismissResult()
        XCTAssertNil(store.verificationWarning)
    }

    func testGroupedTaskKeepsEveryProviderResultUntilDismissedOrReplaced() throws {
        let operations = OperationStore()
        let store = ActivityStore(operationStore: operations)
        let task = operations.begin()
        let first = summary()
        let second = ActivitySummary(id: UUID(), operation: .update, scope: .homebrew(.cask), targetDisplayNames: ["editor"],
                                     date: Date(), status: .succeeded, itemOutcomes: [.init(displayName: "editor", status: .succeeded, reason: nil)])
        try store.record(first)
        try store.record(second)
        operations.end(task)
        XCTAssertEqual(store.latestResults, [first, second])
        XCTAssertEqual(store.latestResults.first?.status, .failed)
        XCTAssertEqual(store.latestResults.last?.status, .succeeded)
        let nextTask = operations.begin()
        try store.record(second)
        operations.end(nextTask)
        XCTAssertEqual(store.latestResults, [second])
        store.dismissResult()
        XCTAssertTrue(store.latestResults.isEmpty)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarActivityTests-\(UUID())")
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
