import XCTest
@testable import Cellar

@MainActor
final class ActivityPresentationTests: XCTestCase {
    func testFiltersCombineAndSelectionTracksVisibleRecords() {
        let formula = summary(scope: .homebrew(.formula), status: .succeeded, names: ["git"])
        let failed = summary(scope: .homebrew(.cask), status: .failed, names: ["editor"])
        let npm = summary(scope: .npm(environment), status: .failed, names: ["typescript"])
        let filter = ActivityFilter(provider: .homebrew, status: .failed, search: "EDITOR")
        let visible = filter.apply([formula, failed, npm], locale: .init(identifier: "en"))
        XCTAssertEqual(visible.map(\.id), [failed.id])
        XCTAssertNil(ActivityFilter.reconciledSelection(formula.id, visible: visible))
        XCTAssertEqual(ActivityFilter.reconciledSelection(failed.id, visible: visible), failed.id)
        XCTAssertEqual(ActivityHistoryState(summaries: [], visible: [], error: nil), .empty)
        XCTAssertEqual(ActivityHistoryState(summaries: [formula], visible: [], error: nil), .noMatches)
        XCTAssertEqual(ActivityHistoryState(summaries: [], visible: [], error: .corruptData), .unavailable)
        let runtime = summary(scope: .nodeRuntime(environment), status: .cancelled, names: ["v24.0.0"])
        let terminal = summary(scope: .shell, status: .failed, names: [])
        let records = [formula, failed, npm, runtime, terminal]
        for (provider, expected) in [(ActivityProviderFilter.formula, formula.id), (.cask, failed.id), (.npm, npm.id), (.nodeRuntime, runtime.id), (.shell, terminal.id)] {
            XCTAssertEqual(ActivityFilter(provider: provider).apply(records, locale: .init(identifier: "en")).map(\.id), [expected])
        }
        XCTAssertEqual(ActivityFilter().apply(records, locale: .init(identifier: "en")).count, records.count)
    }

    func testCopyUsesLocalizedSemanticDataAndEveryItemOutcome() {
        let record = summary(scope: .npm(environment), status: .partiallySucceeded, names: ["git", "editor"], outcomes: [
            .init(displayName: "git", status: .succeeded, reason: nil),
            .init(displayName: "editor", status: .failed, reason: .stateChanged)
        ])
        var copied = ""
        let clipboard = ActivityClipboard(write: { copied = $0; return true })
        XCTAssertTrue(clipboard.copy(record, locale: .init(identifier: "en")))
        XCTAssertTrue(copied.contains("Partially Completed"))
        XCTAssertTrue(copied.contains("Node v22.0.0"))
        XCTAssertTrue(copied.contains("git"))
        XCTAssertTrue(copied.contains("Refresh"))
        XCTAssertTrue(copied.contains("1970"))
        let chinese = ActivityRenderer(locale: .init(identifier: "zh-Hans")).detail(record)
        XCTAssertNotEqual(chinese, copied)
        XCTAssertTrue(chinese.contains("部分完成"))
        XCTAssertFalse(copied.contains(environment.identifier))
    }

    func testSemanticRendererCoversAllCasesAndRestoredShellSteps() throws {
        let renderer = ActivityRenderer(locale: .init(identifier: "en"))
        for operation in ActivityOperationKind.allCases { XCTAssertFalse(renderer.operation(operation).isEmpty) }
        for status in ActivityStatus.allCases { XCTAssertFalse(renderer.status(status).isEmpty); XCTAssertFalse(status.systemImage.isEmpty) }
        for reason in ActivityItemReason.allCases { XCTAssertFalse(renderer.reason(reason).isEmpty) }
        for provider in ActivityProviderFilter.allCases { XCTAssertFalse(renderer.provider(provider).isEmpty) }
        for scope in [ActivityScope.homebrew(.formula), .homebrew(.cask), .homebrewTaps, .homebrewMetadata, .homebrewDiagnostics, .npm(environment), .nodeRuntime(environment), .shell] {
            XCTAssertFalse(renderer.scope(scope).isEmpty)
        }
        let shell = ShellConfigurationResult(operations: [], failure: "private", stepOutcomes: [
            .init(step: .plugins, status: .succeeded), .init(step: .theme, status: .failed)
        ]).activitySummary()
        let restored = try JSONDecoder().decode(ActivitySummary.self, from: JSONEncoder().encode(shell))
        let detail = renderer.detail(restored)
        XCTAssertTrue(detail.contains("Plugin Selection"))
        XCTAssertTrue(detail.contains("Local Theme"))
        XCTAssertTrue(detail.contains("Succeeded: 1"))
        XCTAssertTrue(detail.contains("Failed: 1"))
        XCTAssertFalse(detail.contains("private"))
    }

    func testDiagnosticsAreBoundedRedactedAndSessionOnly() throws {
        let store = ActivityDiagnosticsStore()
        let id = UUID()
        store.record(id: id, operation: .update, scope: .homebrew(.formula), detail: "API_KEY=secret\nCookie: session=private; other=secret\nBearer abc\nhttps://user:pass@example.com?token=token-secret\n/Users/private/file\n-----BEGIN PRIVATE KEY-----\nkey-body\n-----END PRIVATE KEY-----",
                     command: .init(arguments: ["update"], standardOutput: String(repeating: "a", count: 40_000), standardError: "PASSWORD=pwd", terminationStatus: 1,
                                    standardOutputWasTruncated: false, standardErrorWasTruncated: false))
        let record = try XCTUnwrap(store.records.first)
        XCTAssertEqual(record.id, id)
        XCTAssertTrue(record.wasTruncated)
        XCTAssertLessThanOrEqual(record.standardOutput.count, ActivityDiagnosticRecord.textLimit)
        let copy = record.copyText(locale: .init(identifier: "en"))
        for secret in ["=secret", "session=private", "other=", "Bearer abc", "user:pass", "/Users/private", "key-body", "pwd"] {
            XCTAssertFalse(copy.contains(secret), secret)
        }
        XCTAssertTrue(ActivityDiagnosticsStore().records.isEmpty)
        let json = String(decoding: try JSONEncoder().encode(summary(scope: .homebrew(.formula), status: .failed)), as: UTF8.self)
        XCTAssertFalse(json.contains("standardOutput"))
        XCTAssertFalse(json.contains("command"))
        store.record(id: id, operation: .update, scope: nil, detail: "replaced")
        XCTAssertEqual(store.records.count, 1)
    }

    func testFiniteFailureMappingDoesNotExposeRawError() {
        for code in ["plan-stale", "plan-expired", "node-environment-changed", "npm-update-destination-changed", "registry-state-changed"] {
            let reason = ActivityItemReason(error: BridgeError.managerFailure(code: code, detail: "TOKEN=raw"))
            XCTAssertEqual(reason, .stateChanged)
            XCTAssertTrue(ActivityRenderer(locale: .init(identifier: "en")).reason(reason).contains("Refresh"))
        }
        XCTAssertEqual(ActivityItemReason(error: URLError(.notConnectedToInternet)), .network)
        XCTAssertEqual(ActivityItemReason(error: CocoaError(.fileWriteNoPermission)), .permission)
        XCTAssertEqual(ActivityItemReason(error: CancellationError()), .cancelledByUser)
        XCTAssertEqual(ActivityItemReason(error: BridgeError.executableNotFound("/private")), .unavailable)
        let model = AppModel.live()
        let message = model.failureMessage(BridgeError.managerFailure(code: "node-environment-changed", detail: "Foundation dump TOKEN=secret"))
        XCTAssertFalse(message.contains("Foundation"))
        XCTAssertFalse(message.contains("TOKEN"))
        XCTAssertTrue(model.activityDiagnostics.records.last?.detail.contains("[redacted]") == true)
        XCTAssertNil(model.activityStore)
        let absent = NodeSummary(nodePath: "", npmPath: "", nodeVersion: "", npmVersion: "", nvmLoaded: true, globalPrefix: "", globalRoot: "", registry: "")
        XCTAssertNil(absent.activityEnvironment)
        let installed = NodeSummary(nodePath: "/fixture/node", npmPath: "/fixture/npm", nodeVersion: "v22.0.0", npmVersion: "10.0.0", nvmLoaded: true, globalPrefix: "/fixture", globalRoot: "/fixture/lib", registry: "")
        XCTAssertEqual(installed.activityEnvironment?.nodeVersion, "v22.0.0")
    }

    func testCurrentTaskKeepsSemanticContextAndActualProgressUntilOperationEnds() async throws {
        let store = OperationStore()
        let context = ActiveOperationContext(operation: .install, scope: .homebrew(.formula), targets: ["git"], stage: .executing)
        let id = store.begin(context: context)
        let task = Task {
            try await store.performCancellable(operationID: id) {
                store.updateProgress(completed: 1, total: 2)
                while !Task.isCancelled { await Task.yield() }
                throw CancellationError()
            } as Void
        }
        while store.currentOperation?.completed != 1 { await Task.yield() }
        XCTAssertEqual(store.currentOperation?.context, context)
        task.cancel()
        _ = try? await task.value
        XCTAssertEqual(store.currentOperation?.completed, 1)
        XCTAssertEqual(store.currentOperation?.total, 2)
        store.end(id)
        XCTAssertNil(store.currentOperation)
    }

    func testCancellationDoesNotClaimVerificationBeforeReconciliationAndProgressAdaptsToWidth() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "Features/Activity/ActivityView.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("Cancellation Requested · Verifying Completed Changes"))
        XCTAssertTrue(source.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(source.contains("Text(current.context.stage.title)"))
    }

    private var environment: NodeEnvironmentContext { .init(identifier: "/private/node", nodeVersion: "v22.0.0", npmVersion: "10.0.0") }
    private func summary(scope: ActivityScope?, status: ActivityStatus, names: [String] = ["git"], outcomes: [ActivityItemSummary] = []) -> ActivitySummary {
        .init(id: UUID(), operation: .install, scope: scope, targetDisplayNames: names, date: .init(timeIntervalSince1970: 100), status: status, itemOutcomes: outcomes)
    }
}
