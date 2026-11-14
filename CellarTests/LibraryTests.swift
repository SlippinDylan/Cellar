import XCTest
@testable import Cellar

@MainActor
final class LibraryTests: XCTestCase {
    private let capabilityRoot = FileManager.default.temporaryDirectory.appending(path: "CellarLibraryCapability-\(UUID())")

    override func setUpWithError() throws {
        let bin = capabilityRoot.appending(path: ".nvm/versions/node/v22.0.0/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["node", "npm"] {
            let file = bin.appending(path: name)
            try Data("#!/bin/sh\nexit 97\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: capabilityRoot)
    }

    func testUnknownPostflightDoesNotClaimHomebrewRemovedThePackage() async {
        let removal = previewRemoval()
        let provider = PreviewProgressProvider(removal: removal, snapshotUnavailable: true)
        await provider.finish()
        let uninstall = LibraryUninstallModel(model: fixtureModel(provider), loadIconData: { _ in nil })
        await uninstall.prepare(.homebrew(.init(name: "sample", kind: .cask)))
        await uninstall.confirmUninstall()
        XCTAssertEqual(uninstall.result?.outcome.status, .unknown)
        XCTAssertEqual(uninstall.guidance(for: removal.entries[1]), .reviewFailure(.stateUnavailable))
    }

    func testFinalObservationsOverrideHistoricalProgressAndKeepUnknownPathsActionable() async throws {
        let removal = previewRemoval()
        for outcome in [CaskRemovalPathResult.Outcome.retained, .unverified] {
            let paths = [CaskRemovalPathResult(path: removal.entries[0].path, outcome: outcome),
                         CaskRemovalPathResult(path: removal.entries[1].path, outcome: .removed)]
            let provider = PreviewProgressProvider(removal: removal, finalPaths: paths)
            await provider.finish()
            var revealed: [URL] = []
            let uninstall = LibraryUninstallModel(model: fixtureModel(provider), revealFile: { revealed.append($0) }, loadIconData: { _ in nil })
            await uninstall.prepare(.homebrew(.init(name: "sample", kind: .cask)))
            await uninstall.confirmUninstall()
            XCTAssertEqual(uninstall.pathStatus(removal.entries[0]), paths[0].progress.status)
            XCTAssertEqual(uninstall.pathStatus(removal.entries[1]), .removed)
            uninstall.revealInFinder(removal.entries[0])
            uninstall.revealInFinder(removal.entries[1])
            XCTAssertEqual(revealed, [URL(filePath: removal.entries[0].path)])
            if outcome == .unverified {
                XCTAssertEqual(uninstall.guidance(for: removal.entries[0]), .reviewFailure(.stateUnavailable))
            }
        }
    }

    func testCleanupRestartReasonReachesTheRetainedPathThroughPartialExecution() async throws {
        let removal = previewRemoval()
        let failure = CaskRemovalFailure(path: removal.entries[1].path, reason: "Application restarted", recoveryReason: .applicationRunning)
        let provider = PreviewProgressProvider(removal: removal, cleanupFailures: [failure])
        await provider.finish()
        let uninstall = LibraryUninstallModel(model: fixtureModel(provider), loadIconData: { _ in nil })
        await uninstall.prepare(.homebrew(.init(name: "sample", kind: .cask)))
        await uninstall.confirmUninstall()
        XCTAssertEqual(uninstall.result?.outcome.status, .partiallySucceeded)
        XCTAssertEqual(uninstall.result?.outcome.itemOutcomes.first?.reason, .applicationRunning)
        XCTAssertEqual(uninstall.guidance(for: removal.entries[1]), .homebrewRemoved(.applicationRunning))
        XCTAssertEqual(uninstall.guidance(for: removal.entries[2]), .protectedData)
        XCTAssertNil(uninstall.guidance(for: removal.entries[0]))
    }

    func testEachRetainedPathUsesItsOwnRecoveryReason() async throws {
        let original = previewRemoval()
        let other = CaskRemovalEntry(path: "/fixture/Settings", category: .applicationData, estimatedBytes: 10,
                                     disposition: .remove, fingerprint: "settings")
        let removal = CaskRemovalPlan(displayName: original.displayName, appURL: original.appURL,
            entries: original.entries + [other], warnings: original.warnings, ownershipFingerprint: original.ownershipFingerprint)
        for reason in [ActivityItemReason.authorizationFailed, .permission, .stateChanged, .scanIncomplete] {
            let failures = [
                CaskRemovalFailure(path: removal.entries[1].path, reason: "Running", recoveryReason: .applicationRunning),
                CaskRemovalFailure(path: other.path, reason: "Path failure", recoveryReason: reason)
            ]
            let provider = PreviewProgressProvider(removal: removal, cleanupFailures: failures)
            await provider.finish()
            let model = fixtureModel(provider)
            let uninstall = LibraryUninstallModel(model: model, loadIconData: { _ in nil })
            await uninstall.prepare(.homebrew(.init(name: "sample", kind: .cask)))
            await uninstall.confirmUninstall()
            XCTAssertEqual(uninstall.result?.outcome.itemOutcomes.first?.reason, .applicationRunning)
            XCTAssertEqual(uninstall.guidance(for: other), .homebrewRemoved(reason))
            XCTAssertEqual(uninstall.guidance(for: removal.entries[1]), .homebrewRemoved(.applicationRunning))
            XCTAssertEqual(uninstall.guidance(for: removal.entries[2]), .protectedData)
            XCTAssertTrue(model.activityDiagnostics.records.contains { $0.detail.contains("Path failure") })
        }
    }

    func testRemovalGuidancePreservesProtectionAndDistinguishesRunningApps() {
        let entries = previewRemoval().entries
        let application = entries[0]
        let protectedData = entries[2]
        XCTAssertEqual(LibraryUninstallPathGuidance(entry: protectedData, status: .retained, hasFinished: false, failureReason: nil), .protectedData)
        XCTAssertEqual(LibraryUninstallPathGuidance(entry: protectedData, status: .retained, hasFinished: true, failureReason: .providerFailure), .protectedData)
        XCTAssertEqual(LibraryUninstallPathGuidance(entry: application, status: .retained, hasFinished: true, failureReason: .providerFailure), .manualRemoval)
        XCTAssertEqual(LibraryUninstallPathGuidance(entry: application, status: .retained, hasFinished: true, failureReason: .applicationRunning), .quitAndRetry)
        XCTAssertNil(LibraryUninstallPathGuidance(entry: application, status: .pending, hasFinished: false, failureReason: nil))
        XCTAssertNil(LibraryUninstallPathGuidance(entry: application, status: .removed, hasFinished: true, failureReason: nil))
        XCTAssertEqual(LibraryUninstallPathGuidance(entry: application, status: .retained, hasFinished: true,
            failureReason: .applicationRunning, homebrewWasUninstalled: true), .homebrewRemoved(.applicationRunning))
        XCTAssertEqual(LibraryUninstallPathGuidance(entry: protectedData, status: .retained, hasFinished: true,
            failureReason: .applicationRunning, homebrewWasUninstalled: true), .protectedData)
        XCTAssertEqual(LibraryUninstallPathGuidance(entry: application, status: .unverified, hasFinished: true,
            failureReason: .applicationRunning, homebrewWasUninstalled: true), .reviewFailure(.stateUnavailable))
    }

    func testCaskExecutionKeepsSheetAndOnlyChecksConfirmedRemovedPaths() async throws {
        let removal = previewRemoval()
        let started = expectation(description: "Removal started")
        let provider = PreviewProgressProvider(removal: removal, onExecute: { started.fulfill() })
        let uninstall = LibraryUninstallModel(model: fixtureModel(provider), loadIconData: { _ in nil })
        await uninstall.prepare(.homebrew(.init(name: "sample", kind: .cask)))
        let planID = uninstall.confirmation?.id
        let execution = Task { await uninstall.confirmUninstall() }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(uninstall.isExecuting)
        XCTAssertEqual(uninstall.pathStatus(removal.entries[0]), .removing)
        XCTAssertEqual(uninstall.confirmation?.id, planID)
        uninstall.dismissConfirmation()
        XCTAssertNotNil(uninstall.presentedItem, "Running removal cannot dismiss its result owner")
        await uninstall.confirmUninstall()
        await provider.finish()
        await execution.value
        XCTAssertFalse(uninstall.isExecuting)
        XCTAssertTrue(uninstall.hasFinished)
        XCTAssertNotNil(uninstall.presentedItem)
        XCTAssertEqual(uninstall.pathStatus(removal.entries[0]), .removed)
        XCTAssertEqual(uninstall.pathStatus(removal.entries[1]), .retained)
        XCTAssertEqual(uninstall.pathStatus(removal.entries[2]), .retained)
        XCTAssertEqual(uninstall.result?.outcome.status, .partiallySucceeded)
        XCTAssertNil(uninstall.guidance(for: removal.entries[0]))
        XCTAssertEqual(uninstall.guidance(for: removal.entries[1]), .homebrewRemoved(.providerFailure))
        XCTAssertEqual(uninstall.guidance(for: removal.entries[2]), .protectedData)
        uninstall.dismissConfirmation()
        XCTAssertNil(uninstall.presentedItem)
        XCTAssertFalse(uninstall.hasFinished)
    }

    func testCaskExecutionFailureRetainsAllUnconfirmedPaths() async {
        let removal = previewRemoval()
        let provider = PreviewProgressProvider(removal: removal, fails: true)
        await provider.finish()
        let uninstall = LibraryUninstallModel(model: fixtureModel(provider), loadIconData: { _ in nil })
        await uninstall.prepare(.homebrew(.init(name: "sample", kind: .cask)))
        await uninstall.confirmUninstall()
        XCTAssertTrue(uninstall.hasFinished)
        XCTAssertNotNil(uninstall.presentedItem)
        XCTAssertTrue(removal.entries.allSatisfy { uninstall.pathStatus($0) == .retained })
        XCTAssertEqual(uninstall.result?.outcome.status, .failed)
        XCTAssertEqual(uninstall.guidance(for: removal.entries[1]), .manualRemoval)
    }

    func testFinderRevealAcceptsOnlyCurrentPlanPathsAndRejectsRemovedEntries() async {
        let removal = previewRemoval()
        let provider = PreviewProgressProvider(removal: removal)
        await provider.finish()
        var revealed: [URL] = []
        let uninstall = LibraryUninstallModel(model: fixtureModel(provider), revealFile: { revealed.append($0) }, loadIconData: { _ in nil })
        await uninstall.prepare(.homebrew(.init(name: "sample", kind: .cask)))
        uninstall.revealInFinder(removal.entries[0])
        uninstall.revealInFinder(.init(path: "/not-in-plan", category: .cache, estimatedBytes: 1, disposition: .remove, fingerprint: "unknown"))
        XCTAssertEqual(revealed, [URL(filePath: removal.entries[0].path)])
        await uninstall.confirmUninstall()
        uninstall.revealInFinder(removal.entries[0])
        uninstall.revealInFinder(removal.entries[2])
        XCTAssertEqual(revealed, [URL(filePath: removal.entries[0].path), URL(filePath: removal.entries[2].path)])
    }

    private func previewRemoval() -> CaskRemovalPlan {
        .init(displayName: "Sample", appURL: nil, entries: [
            .init(path: "/fixture/Sample.app", category: .application, estimatedBytes: 100, disposition: .homebrew, fingerprint: "app"),
            .init(path: "/fixture/Cache", category: .cache, estimatedBytes: 10, disposition: .remove, fingerprint: "cache"),
            .init(path: "/fixture/Shared", category: .applicationData, estimatedBytes: nil, disposition: .protected, fingerprint: "shared")
        ], warnings: [], ownershipFingerprint: "fixture")
    }

    func testLocalIconAndNameLoadWhileRemovalScanIsPaused() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarIcon-\(UUID().uuidString)")
        let app = root.appending(path: "Sample.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scanStarted = expectation(description: "Scan paused")
        let iconStarted = expectation(description: "Local icon requested before scan finishes")
        let provider = FakeBatchProvider(pausedPlanName: "sample", onPlan: { scanStarted.fulfill() })
        let model = fixtureModel(provider)
        let identity = HomebrewPackageIdentity(name: "sample", kind: .cask)
        let package = HomebrewPackage(identity: identity, displayName: "Sample App", description: nil, homepage: nil,
            installedVersions: ["1"], currentVersion: "1", tap: nil, dependencies: [], pinned: false,
            deprecated: false, disabled: false, artifacts: [.init(kind: "app", values: ["folder/SourceName.app"], category: .installed,
                application: .init(source: "folder/SourceName.app", target: app.path))])
        let snapshot = HomebrewSnapshot(executablePath: "/fake/brew", version: "5", configuration: .init(prefix: "", repository: "", cache: "", cellar: "", values: [:]),
            packages: [package], outdatedPackages: [], taps: [], sectionErrors: [:], controlledPath: "", commandLineToolsAvailable: true)
        model.homebrew = .init(executablePath: snapshot.executablePath, version: snapshot.version, managerAvailable: true, snapshot: snapshot)
        let uninstall = LibraryUninstallModel(model: model, loadIconData: { url in
            XCTAssertEqual(url, app)
            iconStarted.fulfill()
            return nil
        })
        let preparation = Task { await uninstall.prepare(.homebrew(identity)) }
        await fulfillment(of: [scanStarted, iconStarted], timeout: 3)
        XCTAssertTrue(uninstall.isPreparing)
        XCTAssertNil(uninstall.confirmation)
        XCTAssertEqual(uninstall.displayName, "Sample App")
        uninstall.dismissConfirmation()
        await preparation.value
        XCTAssertNil(uninstall.displayName)
        XCTAssertNil(uninstall.appIcon)
    }

    func testSlowIconDoesNotHoldPreparationAndDismissalCancelsIconLoading() async {
        let started = expectation(description: "Icon loading started")
        let cancelled = expectation(description: "Icon loading cancelled")
        let removal = CaskRemovalPlan(displayName: "Sample", appURL: URL(filePath: "/fake/Sample.app"),
                                     entries: [], warnings: [], ownershipFingerprint: "fixture")
        let model = fixtureModel(FakeBatchProvider(caskRemoval: removal))
        let uninstall = LibraryUninstallModel(model: model, loadIconData: { _ in
            let stream = AsyncStream<Data> { _ in started.fulfill() }
            for await data in stream { return data }
            cancelled.fulfill()
            return nil
        })
        await uninstall.prepare(.homebrew(.init(name: "sample", kind: .cask)))
        await fulfillment(of: [started], timeout: 3)
        XCTAssertNotNil(uninstall.confirmation)
        XCTAssertFalse(uninstall.isPreparing)
        XCTAssertFalse(model.isBusy)
        uninstall.dismissConfirmation()
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertNil(uninstall.appIcon)
        XCTAssertNil(uninstall.confirmation)
    }

    func testUninstallPresentsBeforeScanningAndDismissalCancelsPreparation() async {
        let started = expectation(description: "Uninstall preparation started")
        let provider = FakeBatchProvider(pausedPlanName: "one", onPlan: { started.fulfill() })
        let model = fixtureModel(provider)
        let uninstall = LibraryUninstallModel(model: model)
        let item = BatchItem.npm(.init(name: "one", environment: context))
        let preparation = Task { await uninstall.prepare(item) }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(uninstall.presentedItem, item)
        XCTAssertTrue(uninstall.isPreparing)
        XCTAssertNil(uninstall.confirmation)
        uninstall.dismissConfirmation()
        await preparation.value
        XCTAssertNil(uninstall.presentedItem)
        XCTAssertNil(uninstall.confirmation)
        XCTAssertFalse(uninstall.isPreparing)
        XCTAssertNil(uninstall.error)
        XCTAssertFalse(model.isBusy)
        await uninstall.confirmUninstall()
        let executed = await provider.executedNames()
        XCTAssertTrue(executed.isEmpty)
    }

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
        XCTAssertEqual(sanitized.scope, .nodeRuntime(.init(identifier: "nvm:v22.0.0", nodeVersion: context.nodeVersion, npmVersion: context.npmVersion)))
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
        // Return confirms only the non-destructive completion action.
        let completionAction = try XCTUnwrap(confirmation.range(of: "Button(\"OK\", action: uninstall.dismissConfirmation)"))
        let defaultShortcut = try XCTUnwrap(confirmation.range(of: ".keyboardShortcut(.defaultAction)"))
        let cancelAction = try XCTUnwrap(confirmation.range(of: "Button(\"Cancel\", role: .cancel"))
        XCTAssertLessThan(completionAction.lowerBound, defaultShortcut.lowerBound)
        XCTAssertLessThan(defaultShortcut.upperBound, cancelAction.lowerBound)
        XCTAssertEqual(confirmation.components(separatedBy: ".defaultAction").count - 1, 1)
        XCTAssertTrue(confirmation.contains(".cancelAction"))
    }

    private var context: NodeEnvironmentContext {
        .init(identifier: capabilityRoot.appending(path: ".nvm/versions/node/v22.0.0/bin/node").path, nodeVersion: "v22.0.0", npmVersion: "10.0.0")
    }

    private func card(_ name: String, kind: HomebrewPackageKind) -> CatalogCardState {
        guard let card = CatalogCardState(identity: .homebrew(.init(name: name, kind: kind)), displayName: name, description: "Local fixture", currentVersion: "1.0.0", availableVersion: nil, versionStatus: .unknown, websiteURL: nil, progress: .idle, primaryAction: .uninstall) else { preconditionFailure() }
        return card
    }

    private func fixtureModel(_ provider: any BatchOperationProviding) -> AppModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarLibraryUnused-\(UUID().uuidString)")
        let runner = ProcessRunner()
        let service = SystemProbeService(runner: runner, installer: ManagerSnapshotInstaller(applicationSupportDirectory: root), nodeClient: NodeManagerClient(runner: runner, environmentResolver: .init(homeDirectory: root)), shellClient: ShellManagerClient(runner: runner), environmentResolver: .init(homeDirectory: root))
        let model = AppModel(service: service, operationStore: OperationStore(), batchProvider: provider)
        let bin = capabilityRoot.appending(path: ".nvm/versions/node/v22.0.0/bin")
        model.node = NodeSnapshot(summary: .init(nodePath: bin.appending(path: "node").path, npmPath: bin.appending(path: "npm").path,
            nodeVersion: context.nodeVersion, npmVersion: context.npmVersion, nvmLoaded: false, globalPrefix: "/fixture", globalRoot: "/fixture/lib", registry: "https://registry.npmjs.org/"),
            configuration: .init(registry: "https://registry.npmjs.org/", cache: "", prefix: "/fixture", userRegistry: "", projectRegistry: "", globalRegistry: ""),
            packages: [], installations: NodeEnvironmentResolver(homeDirectory: capabilityRoot).installations(), managerStatus: nil, logs: [], outdatedError: nil, maintenanceError: nil, packageEnvironment: context)
        return model
    }
}

private actor PreviewProgressProvider: BatchOperationProviding {
    let base: FakeBatchProvider
    let removal: CaskRemovalPlan
    let fails: Bool
    let snapshotUnavailable: Bool
    let cleanupFailures: [CaskRemovalFailure]
    let finalPaths: [CaskRemovalPathResult]
    let onExecute: @Sendable () -> Void
    let gate: AsyncStream<Void>
    let continuation: AsyncStream<Void>.Continuation

    init(removal: CaskRemovalPlan, fails: Bool = false, snapshotUnavailable: Bool = false, cleanupFailures: [CaskRemovalFailure] = [],
         finalPaths: [CaskRemovalPathResult] = [], onExecute: @escaping @Sendable () -> Void = {}) {
        self.removal = removal
        self.fails = fails
        self.snapshotUnavailable = snapshotUnavailable
        self.cleanupFailures = cleanupFailures
        self.finalPaths = finalPaths
        self.onExecute = onExecute
        base = FakeBatchProvider(caskRemoval: removal)
        (gate, continuation) = AsyncStream<Void>.makeStream()
    }

    func finish() { continuation.yield(()); continuation.finish() }
    func renewHomebrew(_ plan: HomebrewActionPlan) async throws -> HomebrewActionPlan? { try await base.renewHomebrew(plan) }
    func renewNPM(_ plan: NodeActionPlan, environment: NodeEnvironmentContext) async throws -> NodeActionPlan? { try await base.renewNPM(plan, environment: environment) }

    func planHomebrew(_ identity: HomebrewPackageIdentity, operation: BatchOperation) async throws -> HomebrewActionPlan {
        try await base.planHomebrew(identity, operation: operation)
    }
    func executeHomebrew(_ plan: HomebrewActionPlan) async throws -> HomebrewActionResult {
        try await executeHomebrew(plan, caskRemovalProgress: nil)
    }
    func executeHomebrew(_ plan: HomebrewActionPlan, caskRemovalProgress: CaskRemovalProgressHandler?) async throws -> HomebrewActionResult {
        await caskRemovalProgress?(.init(path: removal.entries[0].path, status: .removing))
        onExecute()
        for await _ in gate { break }
        if !fails { await caskRemovalProgress?(.init(path: removal.entries[0].path, status: .removed)) }
        let original = try await base.executeHomebrew(plan)
        let snapshot = HomebrewSnapshot(executablePath: "/fake/brew", version: "5", configuration: .init(prefix: "", repository: "", cache: "", cellar: "", values: [:]),
            packages: fails ? (original.snapshot?.packages ?? []) : [], outdatedPackages: [], taps: [], sectionErrors: [:], controlledPath: "", commandLineToolsAvailable: true)
        return HomebrewActionResult(plan: plan, command: .init(arguments: [], standardOutput: "", standardError: "", terminationStatus: fails ? 1 : 0,
            standardOutputWasTruncated: false, standardErrorWasTruncated: false), snapshot: snapshotUnavailable ? nil : snapshot, postflightError: nil,
            remainingResidualPaths: removal.entries.filter { fails || $0.category != .application }.map { .init(path: $0.path, artifactKind: $0.category.rawValue, estimatedBytes: $0.estimatedBytes) },
            caskRemovalFailures: cleanupFailures, caskRemovalPathResults: finalPaths)
    }
    func refreshHomebrew() async throws -> HomebrewStatus { try await base.refreshHomebrew() }
    func planNPM(_ identity: NPMPackageIdentity, operation: BatchOperation) async throws -> NodeActionPlan { try await base.planNPM(identity, operation: operation) }
    func executeNPM(_ plan: NodeActionPlan, environment: NodeEnvironmentContext) async throws -> NodeOperationResult { try await base.executeNPM(plan, environment: environment) }
    func refreshNPM(_ environment: NodeEnvironmentContext) async throws -> NodeSnapshot { try await base.refreshNPM(environment) }
    func planNodeUninstall(_ identity: NodeRuntimeIdentity) async throws -> NodeActionPlan { try await base.planNodeUninstall(identity) }
    func executeNodeUninstall(_ plan: NodeActionPlan, environment: NodeEnvironmentContext) async throws -> NodeOperationResult { try await base.executeNodeUninstall(plan, environment: environment) }
}
