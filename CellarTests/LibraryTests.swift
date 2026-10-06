import XCTest
@testable import Cellar

@MainActor
final class LibraryTests: XCTestCase {
    func testNPMResidueWarningShowsCopyablePathsAndPartialUninstallResult() async throws {
        let uninstall = LibraryUninstallModel(model: fixtureModel(FakeBatchProvider(npmWarningNames: ["one"])))
        let item = BatchItem.npm(.init(name: "one", environment: context))
        await uninstall.prepare(item)
        await uninstall.confirmUninstall()
        let result = try XCTUnwrap(uninstall.result)
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

    func testLibraryTabsMapExpandedBrewChildrenToExactScopes() {
        XCTAssertFalse(CatalogScopeTab.all.isBrew)
        XCTAssertFalse(CatalogScopeTab.npm.isBrew)
        XCTAssertTrue([CatalogScopeTab.brew, .brewAll, .formula, .cask].allSatisfy(\.isBrew))
        XCTAssertEqual(CatalogScopeTab.all.scope, .all)
        XCTAssertEqual(CatalogScopeTab.npm.scope, .npm)
        XCTAssertEqual(CatalogScopeTab.brewAll.subtype, .all)
        XCTAssertEqual(CatalogScopeTab.formula.subtype, .formula)
        XCTAssertEqual(CatalogScopeTab.cask.subtype, .cask)
    }

    func testUninstallIntentNormalizesOneItemAndRejectsMultipleTargets() throws {
        let one = BatchItem.homebrew(.init(name: " one ", kind: .formula))
        let normalized = BatchItem.homebrew(.init(name: "one", kind: .formula))
        let intent = try XCTUnwrap(LibraryCatalog.uninstallIntent(one))
        XCTAssertEqual(intent.items, [normalized])
        XCTAssertEqual(intent.operation, .uninstall)
        XCTAssertNil(LibraryCatalog.uninstallIntent(.homebrew(.init(name: "  ", kind: .formula))))
        XCTAssertNil(BatchIntent(operation: .uninstall, items: [normalized, .homebrew(.init(name: "two", kind: .formula))]))
    }

    func testSingleUninstallOnlyExecutesAfterConfirmationAndReconciles() async throws {
        let provider = FakeBatchProvider()
        let model = fixtureModel(provider)
        let uninstall = LibraryUninstallModel(model: model)
        await uninstall.prepare(.npm(.init(name: "one", environment: context)))
        XCTAssertNotNil(uninstall.confirmation)
        let before = await provider.executedNames()
        XCTAssertEqual(before, [])
        uninstall.dismissConfirmation()
        await uninstall.confirmUninstall()
        let dismissed = await provider.executedNames()
        XCTAssertEqual(dismissed, [])
        await uninstall.prepare(.npm(.init(name: "one", environment: context)))
        await uninstall.confirmUninstall()
        let after = await provider.executedNames()
        XCTAssertEqual(after, ["one"])
        XCTAssertEqual(uninstall.result?.outcome.itemOutcomes.map(\.status), [.succeeded])
        XCTAssertEqual(model.node?.summary.nodeVersion, context.nodeVersion)
        XCTAssertEqual(model.nodeUpdateState, .available)
        await uninstall.confirmUninstall()
        let replay = await provider.executedNames()
        XCTAssertEqual(replay, ["one"])
    }

    func testNodeRuntimeBatchIsDistinctAndOnlyAllowsUninstall() throws {
        let item = BatchItem.nodeRuntime(.init(version: "v18.0.0", environment: context))
        XCTAssertEqual(try XCTUnwrap(BatchIntent(operation: .uninstall, items: [item])).scope, .nodeRuntime(context))
        XCTAssertNil(BatchIntent(operation: .install, items: [item]))
        XCTAssertNil(BatchIntent(operation: .update, items: [item]))
        XCTAssertNil(BatchIntent(operation: .uninstall, items: [item, .npm(.init(name: "example", environment: context))]))
        XCTAssertNil(BatchIntent(operation: .uninstall, items: [item, .nodeRuntime(.init(version: "v19.0.0", environment: context))]))
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
        let snapshot = HomebrewSnapshot(executablePath: "/fixture/brew", version: "5.0.0", configuration: .init(prefix: "", repository: "", cache: "", cellar: "", values: [:]), packages: [package], outdatedPackages: [.init(identity: identity, installedVersions: ["1.0.0"], currentVersion: "3.0.0")], taps: [], sectionErrors: [:], controlledPath: "", commandLineToolsAvailable: true)
        let cards = LibraryCatalog.cards(homebrew: snapshot, node: nil, homebrewUpdates: .available, nodeUpdates: .notLoaded)
        let card = try XCTUnwrap(cards.first)
        XCTAssertEqual(card.identity, .homebrew(identity))
        XCTAssertEqual(card.currentVersion, "1.0.0")
        XCTAssertEqual(card.availableVersion, "3.0.0")
        XCTAssertEqual(card.versionStatus, .behind)
        XCTAssertEqual(card.description, "Local description")
        XCTAssertEqual(card.websiteURL?.host, "fixture.invalid")
        XCTAssertEqual(LibraryCatalog.cards(homebrew: snapshot, node: nil, homebrewUpdates: .notLoaded, nodeUpdates: .notLoaded).first?.versionStatus, .unknown)
    }

    func testProtectedNodeRejectsPreparationWithoutConfirmationOrExecution() async {
        let provider = FakeBatchProvider(protectedNames: ["v22.0.0", "v20.0.0"])
        let uninstall = LibraryUninstallModel(model: fixtureModel(provider))
        for version in ["v22.0.0", "v20.0.0"] {
            await uninstall.prepare(.nodeRuntime(.init(version: version, environment: context)))
            XCTAssertNil(uninstall.confirmation)
            XCTAssertEqual(uninstall.error, .protectedTarget)
        }
        let executed = await provider.executedNames()
        XCTAssertTrue(executed.isEmpty)
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

    func testLibraryHasNativeSearchAndNoBulkUninstallControls() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appending(path: "Features/Library/LibraryView.swift"), encoding: .utf8)
        let commands = try String(contentsOf: root.appending(path: "Features/AppCommands.swift"), encoding: .utf8)
        for forbidden in ["NavigationLink", "onTapGesture", "Process(", "AsyncImage", "Table("] {
            XCTAssertFalse(view.contains(forbidden), forbidden)
        }
        XCTAssertTrue(view.contains("@Binding private var query: String"))
        XCTAssertFalse(view.contains(".searchable("))
        XCTAssertFalse(view.contains(".toolbar {"))
        XCTAssertTrue(view.contains(".focusedSceneValue(\\.catalogSearchAction)"))
        XCTAssertTrue(view.contains(".focusedSceneValue(\\.libraryTabs"))
        XCTAssertFalse(view.contains("Picker(\"Library Scope\""))
        XCTAssertFalse(view.contains("Picker(\"Homebrew Type\""))
        XCTAssertFalse(view.contains(".pickerStyle(.segmented)"))
        XCTAssertFalse(view.contains("TabView(selection:"))
        for removed in ["libraryActions", "Uninstall Selected", "Manage Scope", "Toggle(", ".checkbox"] {
            XCTAssertFalse(view.contains(removed), removed)
            XCTAssertFalse(commands.contains(removed), removed)
        }
        XCTAssertTrue(commands.contains("catalogSearchAction?()"))
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
