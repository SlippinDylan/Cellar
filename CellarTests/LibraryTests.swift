import XCTest
@testable import Cellar

@MainActor
final class LibraryTests: XCTestCase {
    func testNPMResidueWarningShowsCopyablePathsAndPartialManagementResult() async throws {
        let management = LibraryManagementModel(model: fixtureModel(FakeBatchProvider(npmWarningNames: ["one"])))
        let item = BatchItem.npm(.init(name: "one", environment: context))
        await management.prepare([item])
        await management.confirmUninstall()
        let result = try XCTUnwrap(management.result)
        XCTAssertEqual(result.outcome.status, .partiallySucceeded)
        let view = LibraryResultView(result: result)
        XCTAssertEqual(view.residualPaths(for: item), ["/private/fake/lib/node_modules/one", "/private/fake/bin/one"])
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "Features/Library/LibraryUninstallConfirmation.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(".textSelection(.enabled)"))
        XCTAssertFalse(source.contains("removeItem"))
    }
    func testLocalScopeFilterRetainsTypeAndSearchesCaseAndDiacritics() throws {
        let formula = card("café", kind: .formula)
        let cask = card("café", kind: .cask)
        let npm = try XCTUnwrap(CatalogCardState(identity: .npm(.init(name: "café", environment: context)), displayName: "café", description: nil, currentVersion: "1.0.0", availableVersion: nil, versionStatus: .unknown, websiteURL: nil, progress: .idle, primaryAction: .uninstall))
        let cards = [formula, cask, npm]
        XCTAssertEqual(LibraryCatalog.filtered(cards, scope: .all, subtype: .all, query: " CAFE ").count, 3)
        XCTAssertEqual(LibraryCatalog.filtered(cards, scope: .homebrew, subtype: .formula, query: "").map(\.identity), [formula.identity])
        XCTAssertEqual(LibraryCatalog.filtered(cards, scope: .homebrew, subtype: .cask, query: "cafe").map(\.identity), [cask.identity])
        XCTAssertEqual(LibraryCatalog.filtered(cards, scope: .npm, subtype: .all, query: "").first?.nodeEnvironment, context)
        XCTAssertTrue(LibraryCatalog.filtered(cards, scope: .all, subtype: .all, query: "missing").isEmpty)
    }

    func testEmptyLoadingFailureAndNoMatchesAreDistinct() {
        XCTAssertEqual(LibraryContentState(readStates: [.loading], totalCount: 0, matchCount: 0), .loading)
        XCTAssertEqual(LibraryContentState(readStates: [.failed], totalCount: 0, matchCount: 0), .failed)
        XCTAssertEqual(LibraryContentState(readStates: [.available], totalCount: 0, matchCount: 0), .empty)
        XCTAssertEqual(LibraryContentState(readStates: [.available], totalCount: 3, matchCount: 0), .noMatches)
        XCTAssertEqual(LibraryContentState(readStates: [.failed, .available], totalCount: 3, matchCount: 1), .available)
    }

    func testSelectionNormalizesDeduplicatesAndRejectsMixedScopeOrOverLimit() throws {
        let one = BatchItem.homebrew(.init(name: " one ", kind: .formula))
        let duplicate = BatchItem.homebrew(.init(name: "one", kind: .formula))
        let intent = try XCTUnwrap(LibraryCatalog.uninstallIntent([one, duplicate]))
        XCTAssertEqual(intent.items, [duplicate])
        XCTAssertEqual(intent.operation, .uninstall)
        XCTAssertNil(LibraryCatalog.uninstallIntent([one, .homebrew(.init(name: "two", kind: .cask))]))
        XCTAssertNil(LibraryCatalog.uninstallIntent([.npm(.init(name: "one", environment: context)), .npm(.init(name: "two", environment: .init(identifier: "other", nodeVersion: "v20.0.0", npmVersion: "10.0.0")))]))
        XCTAssertNil(LibraryCatalog.uninstallIntent((0...100).map { .homebrew(.init(name: "item\($0)", kind: .formula)) }))
    }

    func testSingleUninstallOnlyExecutesAfterConfirmationAndReconciles() async throws {
        let provider = FakeBatchProvider()
        let model = fixtureModel(provider)
        let management = LibraryManagementModel(model: model)
        await management.prepare([.npm(.init(name: "one", environment: context))])
        XCTAssertNotNil(management.confirmation)
        let before = await provider.executedNames()
        XCTAssertEqual(before, [])
        management.dismissConfirmation()
        await management.confirmUninstall()
        let dismissed = await provider.executedNames()
        XCTAssertEqual(dismissed, [])
        await management.prepare([.npm(.init(name: "one", environment: context))])
        await management.confirmUninstall()
        let after = await provider.executedNames()
        XCTAssertEqual(after, ["one"])
        XCTAssertEqual(management.result?.outcome.itemOutcomes.map(\.status), [.succeeded])
        XCTAssertEqual(model.node?.summary.nodeVersion, context.nodeVersion)
        XCTAssertEqual(model.nodeUpdateState, .available)
        await management.confirmUninstall()
        let replay = await provider.executedNames()
        XCTAssertEqual(replay, ["one"])
    }

    func testNodeRuntimeBatchIsDistinctAndOnlyAllowsUninstall() throws {
        let item = BatchItem.nodeRuntime(.init(version: "v18.0.0", environment: context))
        XCTAssertEqual(try XCTUnwrap(BatchIntent(operation: .uninstall, items: [item])).scope, .nodeRuntime(context))
        XCTAssertNil(BatchIntent(operation: .install, items: [item]))
        XCTAssertNil(BatchIntent(operation: .update, items: [item]))
        XCTAssertNil(BatchIntent(operation: .uninstall, items: [item, .npm(.init(name: "example", environment: context))]))
    }

    func testMappingUsesCompletedEnrichmentAndExactEnvironmentIdentity() throws {
        let summary = NodeSummary(nodePath: "/fixture/node-a", npmPath: "/fixture/npm-a", nodeVersion: "v22.0.0", npmVersion: "10.0.0", nvmLoaded: true, globalPrefix: "/fixture", globalRoot: "/fixture/lib", registry: "https://fixture.invalid")
        let node = NodeSnapshot(summary: summary, configuration: .init(registry: "", cache: "", prefix: "", userRegistry: "", projectRegistry: "", globalRegistry: ""), packages: [
            .init(name: "behind", installedVersion: "1.0.0", wantedVersion: "1.0.0", latestVersion: "2.0.0"),
            .init(name: "ahead", installedVersion: "3.0.0", wantedVersion: nil, latestVersion: "2.0.0"),
            .init(name: "unknown", installedVersion: "git", wantedVersion: nil, latestVersion: "2.0.0")
        ], installations: [], managerStatus: nil, logs: [], outdatedError: nil, maintenanceError: nil)
        let cards = LibraryCatalog.cards(homebrew: nil, node: node, homebrewUpdates: .notLoaded, nodeUpdates: .available)
        XCTAssertEqual(cards.map(\.versionStatus), [.ahead, .behind, .unknown])
        XCTAssertTrue(cards.allSatisfy { $0.primaryAction == .uninstall })
        XCTAssertTrue(cards.allSatisfy { $0.nodeEnvironment?.identifier == summary.nodePath })
        XCTAssertEqual(cards.first?.currentVersion, "3.0.0")
        let unchecked = LibraryCatalog.cards(homebrew: nil, node: node, homebrewUpdates: .notLoaded, nodeUpdates: .loading)
        XCTAssertTrue(unchecked.allSatisfy { $0.versionStatus == .unknown && $0.availableVersion == nil })
        let failed = LibraryCatalog.cards(homebrew: nil, node: node, homebrewUpdates: .notLoaded, nodeUpdates: .failed)
        XCTAssertEqual(failed.count, 3)
        XCTAssertTrue(failed.allSatisfy { $0.versionStatus == .unknown })
    }

    func testHomebrewMappingRetainsFullTypeIdentityAndSafeWebsite() throws {
        let identity = HomebrewPackageIdentity(name: "acme/tools/one", kind: .formula)
        let package = HomebrewPackage(identity: identity, displayName: "one", description: "Local description", homepage: "https://fixture.invalid/one", installedVersions: ["1.0.0"], currentVersion: "2.0.0", tap: "acme/tools", dependencies: [], pinned: false, deprecated: false, disabled: false, artifacts: [])
        let snapshot = HomebrewSnapshot(executablePath: "/fixture/brew", version: "5.0.0", configuration: .init(prefix: "", repository: "", cache: "", cellar: "", values: [:]), packages: [package], outdatedPackages: [.init(identity: identity, installedVersions: ["1.0.0"], currentVersion: "2.0.0")], taps: [], sectionErrors: [:], controlledPath: "", commandLineToolsAvailable: true)
        let cards = LibraryCatalog.cards(homebrew: snapshot, node: nil, homebrewUpdates: .available, nodeUpdates: .notLoaded)
        let card = try XCTUnwrap(cards.first)
        XCTAssertEqual(card.identity, .homebrew(identity))
        XCTAssertEqual(card.currentVersion, "1.0.0")
        XCTAssertEqual(card.availableVersion, "2.0.0")
        XCTAssertEqual(card.versionStatus, .behind)
        XCTAssertEqual(card.description, "Local description")
        XCTAssertEqual(card.websiteURL?.host, "fixture.invalid")
        XCTAssertEqual(LibraryCatalog.cards(homebrew: snapshot, node: nil, homebrewUpdates: .notLoaded, nodeUpdates: .notLoaded).first?.versionStatus, .unknown)
    }

    func testProtectedNodeRejectsPreparationWithoutConfirmationOrExecution() async {
        let provider = FakeBatchProvider(protectedNames: ["v22.0.0", "v20.0.0"])
        let management = LibraryManagementModel(model: fixtureModel(provider))
        for version in ["v22.0.0", "v20.0.0"] {
            await management.prepare([.nodeRuntime(.init(version: version, environment: context))])
            XCTAssertNil(management.confirmation)
            XCTAssertEqual(management.error, .protectedTarget)
        }
        let executed = await provider.executedNames()
        XCTAssertTrue(executed.isEmpty)
    }

    func testNodeRuntimeSequentialBatchContinuesFailureAndKeepsActivityScope() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarRuntimeActivity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let activity = ActivityStore(applicationSupportRoot: root)
        let provider = FakeBatchProvider(failingNames: ["v18.0.0"])
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: OperationStore(), activityStore: activity)
        let items: [BatchItem] = ["v16.0.0", "v18.0.0", "v20.0.0"].map { .nodeRuntime(.init(version: $0, environment: context)) }
        let plan = try await coordinator.prepare(XCTUnwrap(BatchIntent(operation: .uninstall, items: items)))
        let result = try await coordinator.execute(plan)
        XCTAssertEqual(result.outcome.itemOutcomes.map(\.status), [.succeeded, .failed, .succeeded])
        let executed = await provider.executedNames()
        let refreshes = await provider.refreshCount()
        let maximum = await provider.maximumConcurrentCount()
        XCTAssertEqual(executed, ["v16.0.0", "v18.0.0", "v20.0.0"])
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(maximum, 1)
        XCTAssertEqual(activity.summaries.first?.scope, .nodeRuntime(context))
        let restored = ActivityStore(applicationSupportRoot: root)
        try restored.load()
        XCTAssertEqual(restored.summaries, activity.summaries)
    }

    func testNodeRuntimeCancellationStopsUnstartedAndReconciles() async throws {
        let started = expectation(description: "Node uninstall started")
        let provider = FakeBatchProvider(pausedName: "v18.0.0", onPaused: { started.fulfill() })
        let store = OperationStore()
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: store)
        let items: [BatchItem] = ["v16.0.0", "v18.0.0", "v20.0.0"].map { .nodeRuntime(.init(version: $0, environment: context)) }
        let plan = try await coordinator.prepare(XCTUnwrap(BatchIntent(operation: .uninstall, items: items)))
        let task = Task { try await coordinator.execute(plan) }
        await fulfillment(of: [started], timeout: 3)
        store.cancelActiveTask()
        let result = try await task.value
        XCTAssertEqual(result.outcome.itemOutcomes.map(\.status), [.succeeded, .cancelled, .cancelled])
        XCTAssertEqual(result.refreshStatus, .succeeded)
        let executed = await provider.executedNames()
        XCTAssertEqual(executed, ["v16.0.0", "v18.0.0"])
        XCTAssertFalse(store.hasActiveOperations)
    }

    func testRuntimeActivityStripsExecutablePathAndRejectsInvalidVersionTargets() throws {
        let privateContext = NodeEnvironmentContext(identifier: "/private/fixture/user/.nvm/node", nodeVersion: "v22.0.0", npmVersion: "10.0.0")
        let summary = ActivitySummary(id: UUID(), operation: .uninstall, scope: .nodeRuntime(privateContext), targetDisplayNames: ["v18.0.0"], date: Date(), status: .succeeded, itemOutcomes: [.init(displayName: "v18.0.0", status: .succeeded, reason: nil)])
        let sanitized = try ActivitySummarySanitizer.sanitize(summary)
        XCTAssertEqual(sanitized.scope, .nodeRuntime(context))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(sanitized), as: UTF8.self).contains("private"))
        let invalid = ActivitySummary(id: UUID(), operation: .uninstall, scope: .nodeRuntime(privateContext), targetDisplayNames: ["../../private"], date: Date(), status: .failed, itemOutcomes: [])
        XCTAssertThrowsError(try ActivitySummarySanitizer.sanitize(invalid))
    }

    func testLibraryLabelsCompileInAllThreeLanguages() {
        for (language, expected) in [("en", "Node Runtime"), ("zh-Hans", "Node 运行时"), ("zh-Hant", "Node 執行環境")] {
            var resource = LibraryManagementScope.nodeRuntime.libraryTitle
            resource.locale = Locale(identifier: language)
            XCTAssertEqual(String(localized: resource), expected)
        }
    }

    func testLibraryHasNativeSearchFocusAndExplicitManageControls() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appending(path: "Features/Library/LibraryView.swift"), encoding: .utf8)
        let commands = try String(contentsOf: root.appending(path: "Features/AppCommands.swift"), encoding: .utf8)
        for forbidden in ["NavigationLink", "onTapGesture", "Process(", "AsyncImage", "Table("] {
            XCTAssertFalse(view.contains(forbidden), forbidden)
        }
        XCTAssertTrue(view.contains(".searchFocused($searchFocused)"))
        XCTAssertTrue(view.contains(".focusedSceneValue"))
        XCTAssertTrue(view.contains("Toggle("))
        XCTAssertTrue(view.contains(".checkbox"))
        XCTAssertTrue(commands.contains("libraryActions?.focusSearch()"))
        XCTAssertTrue(commands.contains(".keyboardShortcut(\"f\", modifiers: .command)"))
        let confirmation = try String(contentsOf: root.appending(path: "Features/Library/LibraryUninstallConfirmation.swift"), encoding: .utf8)
        XCTAssertFalse(confirmation.contains(".defaultAction"))
        XCTAssertTrue(confirmation.contains(".cancelAction"))
    }

    private var context: NodeEnvironmentContext {
        .init(identifier: "nvm:v22.0.0", nodeVersion: "v22.0.0", npmVersion: "10.0.0")
    }

    private func card(_ name: String, kind: HomebrewPackageKind) -> CatalogCardState {
        guard let card = CatalogCardState(identity: .homebrew(.init(name: name, kind: kind)), displayName: name, description: "Local fixture", currentVersion: "1.0.0", availableVersion: nil, versionStatus: .unknown, websiteURL: nil, progress: .idle, primaryAction: .uninstall) else { preconditionFailure() }
        return card
    }

    private func fixtureModel(_ provider: FakeBatchProvider) -> AppModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarLibraryUnused-\(UUID().uuidString)")
        let runner = ProcessRunner()
        let service = SystemProbeService(runner: runner, installer: ManagerSnapshotInstaller(applicationSupportDirectory: root), nodeClient: NodeManagerClient(runner: runner, environmentResolver: .init(homeDirectory: root)), shellClient: ShellManagerClient(runner: runner), environmentResolver: .init(homeDirectory: root))
        return AppModel(service: service, operationStore: OperationStore(), batchProvider: provider)
    }
}
