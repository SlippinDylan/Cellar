import AppKit
import XCTest
@testable import Cellar

@MainActor
final class UpdatesTests: XCTestCase {
    func testScopesKeepExactTypedTargetsAndSuppressNPMAheadUnknownAndCurrent() throws {
        let cards = UpdatesCatalog.cards(homebrew: brewSnapshot(), node: nodeSnapshot(), homebrewUpdates: .available, nodeUpdates: .available)
        XCTAssertEqual(cards.count, 5)
        let npm = cards.filter { $0.identity.providerScope == .npm }
        XCTAssertEqual(npm.map(\.versionStatus), [.ahead, .behind, .unknown])
        XCTAssertEqual(npm.filter { $0.primaryAction == .update }.map(\.displayName), ["behind"])
        XCTAssertTrue(npm.allSatisfy { $0.nodeEnvironment == context })
        let formula = UpdatesCatalog.visible(cards, scope: .homebrew, subtype: .formula)
        let cask = UpdatesCatalog.visible(cards, scope: .homebrew, subtype: .cask)
        XCTAssertEqual(formula.map(\.batchItem), [.homebrew(.init(name: "same", kind: .formula))])
        XCTAssertEqual(cask.map(\.batchItem), [.homebrew(.init(name: "same", kind: .cask))])
        let groups = UpdatesCatalog.intents(for: UpdatesCatalog.visible(cards, scope: .all, subtype: .cask))
        XCTAssertEqual(groups.map(\.scope), [.homebrew(.formula), .homebrew(.cask), .npm(context)])
        XCTAssertEqual(groups.flatMap(\.items).count, 3)
        XCTAssertEqual(UpdatesCatalog.intents(for: formula).count, 1)
        XCTAssertEqual(UpdatesCatalog.intents(for: UpdatesCatalog.visible(cards, scope: .npm, subtype: .all)).flatMap(\.items).map(\.displayIdentifier), ["behind"])
    }

    func testReadStatesAndSubtypeEmptyAreDistinctAndFailedKnownCardsAreNonActionable() {
        XCTAssertEqual(UpdatesContentState(states: [.notLoaded], totalCount: 0, visibleCount: 0), .notLoaded)
        XCTAssertEqual(UpdatesContentState(states: [.loading], totalCount: 0, visibleCount: 0), .loading)
        XCTAssertEqual(UpdatesContentState(states: [.failed], totalCount: 0, visibleCount: 0), .failed)
        XCTAssertEqual(UpdatesContentState(states: [.available], totalCount: 0, visibleCount: 0), .empty)
        XCTAssertEqual(UpdatesContentState(states: [.available], totalCount: 2, visibleCount: 0), .noMatches)
        XCTAssertEqual(UpdatesContentState(states: [.failed, .available], totalCount: 2, visibleCount: 2), .available)
        let failed = UpdatesCatalog.cards(homebrew: brewSnapshot(), node: nodeSnapshot(), homebrewUpdates: .failed, nodeUpdates: .failed)
        XCTAssertFalse(failed.isEmpty)
        XCTAssertTrue(failed.allSatisfy { $0.primaryAction == nil && $0.versionStatus == .unknown })
        XCTAssertEqual(failed.first { $0.displayName == "behind" }?.availableVersion, "2.0.0")
    }

    func testSingleUpdateStartsDirectlyAndDuplicateDoesNotChangeActiveResultOrError() async throws {
        let started = expectation(description: "direct update started")
        let provider = FakeBatchProvider(pausedName: "behind", onPaused: { started.fulfill() })
        let model = fixtureModel(provider)
        let updates = PackageUpdatesModel(model: model)
        let card = try XCTUnwrap(model.updateCards.first { $0.displayName == "behind" })
        let task = Task { await updates.update(card) }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertNil(updates.confirmation)
        await updates.update(card)
        XCTAssertNil(updates.error)
        XCTAssertNil(updates.result)
        XCTAssertEqual(model.operationStore.activeOperationCount, 1)
        model.operationStore.cancelActiveTask()
        await task.value
        XCTAssertEqual(updates.result?.groups.first?.outcome.itemOutcomes.map(\.status), [.cancelled])
        let names = await provider.executedNames()
        XCTAssertEqual(names, ["behind"])
    }

    func testUpdateAllPreparesExactVisibleGroupsBeforeOneConsumableConfirmation() async throws {
        let provider = FakeBatchProvider(planFailureNames: ["same"])
        let model = fixtureModel(provider)
        let updates = PackageUpdatesModel(model: model)
        let visible = UpdatesCatalog.visible(model.updateCards, scope: .all, subtype: .all)
        await updates.prepareAll(visible, scope: .all, subtype: .all)
        let preview = try XCTUnwrap(updates.confirmation)
        XCTAssertEqual(preview.plan.groups.map(\.intent.scope), [.homebrew(.formula), .homebrew(.cask), .npm(context)])
        XCTAssertEqual(preview.plan.groups.flatMap(\.items).map(\.status), [.unavailable, .unavailable, .ready])
        XCTAssertEqual(preview.plan.executableCount, 1)
        let before = await provider.executedNames()
        XCTAssertTrue(before.isEmpty)
        // Changing what is displayed cannot widen the captured confirmation.
        _ = UpdatesCatalog.visible(model.updateCards, scope: .homebrew, subtype: .formula)
        await updates.confirmUpdateAll()
        await updates.confirmUpdateAll()
        let names = await provider.executedNames()
        XCTAssertEqual(names, ["behind"])
        XCTAssertEqual(updates.result?.groups.flatMap { $0.outcome.itemOutcomes }.map(\.status), [.failed, .failed, .succeeded])
    }

    func testCompositeRunsTypedGroupsSequentiallyAndReconcilesEachProviderOnce() async throws {
        let provider = FakeBatchProvider(failingNames: ["formula"])
        let store = OperationStore()
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: store)
        let plan = try await coordinator.prepareUpdates(groupIntents())
        XCTAssertEqual(plan.groups.map(\.intent.scope), [.homebrew(.formula), .homebrew(.cask), .npm(context)])
        let result = try await coordinator.executeUpdates(plan)
        let names = await provider.executedNames()
        let refreshes = await provider.refreshCount()
        XCTAssertEqual(names, ["formula", "cask", "behind"])
        XCTAssertEqual(refreshes, 2)
        XCTAssertEqual(result.groups.flatMap { $0.outcome.itemOutcomes }.map(\.status), [.partiallySucceeded, .succeeded, .succeeded])
        for group in result.groups.prefix(2) {
            guard case .homebrew(let diagnostic) = group.providerResults[0] else { return XCTFail("Expected typed Homebrew update") }
            XCTAssertEqual(diagnostic.plan.action, .upgrade)
            XCTAssertEqual(diagnostic.plan.targets.first?.kind, group.outcome.intent.scope == .homebrew(.formula) ? .formula : .cask)
        }
        XCTAssertFalse(store.hasActiveOperations)
        do { _ = try await coordinator.executeUpdates(plan); XCTFail("Confirmation must be consumed") }
        catch { XCTAssertEqual(error as? BatchOperationError, .planUnavailable) }
    }

    func testCompositeCancellationStopsLaterGroupsAndRetainsOneOwnerThroughRefresh() async throws {
        let started = expectation(description: "npm started after both Homebrew groups")
        let provider = FakeBatchProvider(pausedName: "behind", onPaused: { started.fulfill() })
        let store = OperationStore()
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: store)
        let npm = try XCTUnwrap(BatchIntent(operation: .update, items: ["behind", "later"].map { .npm(.init(name: $0, environment: context)) }))
        let plan = try await coordinator.prepareUpdates(Array(groupIntents().prefix(2)) + [npm])
        let task = Task { try await coordinator.executeUpdates(plan) }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(store.activeOperationCount, 1)
        XCTAssertEqual(AppTerminationPolicy.reply(hasActiveOperations: store.hasActiveOperations), .terminateCancel)
        do { _ = try await coordinator.prepare(groupIntents()[0]); XCTFail("Other writes must be excluded") }
        catch { XCTAssertEqual(error as? BatchOperationError, .busy) }
        store.cancelActiveTask()
        let result = try await task.value
        XCTAssertEqual(result.groups.flatMap { $0.outcome.itemOutcomes }.map(\.status), [.succeeded, .succeeded, .cancelled, .cancelled])
        let refreshes = await provider.refreshCount()
        XCTAssertEqual(refreshes, 2)
        XCTAssertFalse(store.hasActiveOperations)
    }

    func testCancellationOfFirstGroupStopsAllUnstartedProviderGroups() async throws {
        let started = expectation(description: "first group started")
        let provider = FakeBatchProvider(pausedName: "behind", onPaused: { started.fulfill() })
        let store = OperationStore()
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: store)
        let groups = try groupIntents()
        let plan = try await coordinator.prepareUpdates([groups[2], groups[0], groups[1]])
        let task = Task { try await coordinator.executeUpdates(plan) }
        await fulfillment(of: [started], timeout: 3)
        store.cancelActiveTask()
        let result = try await task.value
        XCTAssertEqual(result.groups.flatMap { $0.outcome.itemOutcomes }.map(\.status), [.cancelled, .cancelled, .cancelled])
        XCTAssertEqual(result.groups.map(\.refreshStatus), [.succeeded, .notNeeded, .notNeeded])
        let names = await provider.executedNames()
        let refreshes = await provider.refreshCount()
        XCTAssertEqual(names, ["behind"])
        XCTAssertEqual(refreshes, 1)
    }

    func testCompositeFinalRefreshRetainsGlobalOwnerAndIgnoresParentCancellation() async throws {
        let started = expectation(description: "final npm reconciliation started")
        let provider = FakeBatchProvider(pauseRefresh: true, onRefresh: { started.fulfill() })
        let store = OperationStore()
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: store)
        let plan = try await coordinator.prepareUpdates(groupIntents())
        let task = Task { try await coordinator.executeUpdates(plan) }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(store.activeOperationCount, 1)
        XCTAssertNil(store.activeTask)
        XCTAssertEqual(AppTerminationPolicy.reply(hasActiveOperations: store.hasActiveOperations), .terminateCancel)
        do { _ = try await coordinator.prepare(groupIntents()[0]); XCTFail("Reconciliation retains ownership") }
        catch { XCTAssertEqual(error as? BatchOperationError, .busy) }
        task.cancel()
        await provider.resumeRefresh()
        let result = try await task.value
        XCTAssertTrue(result.groups.allSatisfy { $0.refreshStatus == .succeeded })
        let refreshes = await provider.refreshCount()
        XCTAssertEqual(refreshes, 2)
        XCTAssertFalse(store.hasActiveOperations)
    }

    func testTypedUpdateChunksKeepEveryVisibleTargetOverTheExistingBatchLimit() throws {
        let cards = try (0..<205).map { index in
            try XCTUnwrap(CatalogCardState(identity: .homebrew(.init(name: "item\(index)", kind: .formula)), displayName: "item\(index)", description: nil, currentVersion: "1.0.0", availableVersion: "2.0.0", versionStatus: .behind, websiteURL: nil, progress: .idle, primaryAction: .update))
        }
        let intents = UpdatesCatalog.intents(for: cards)
        XCTAssertEqual(intents.map { $0.items.count }, [100, 100, 5])
        XCTAssertEqual(intents.flatMap(\.items), cards.map(\.batchItem))
        XCTAssertTrue(intents.allSatisfy { $0.scope == .homebrew(.formula) })
    }

    func testOutdatedFailureKeepsBothKnownVersionSetsAndDoesNotClaimCurrent() async {
        let provider = FakeBatchProvider()
        let model = fixtureModel(provider, outdated: HomeOutdatedDependencies(homebrew: { throw URLError(.notConnectedToInternet) }, node: { _ in throw URLError(.notConnectedToInternet) }))
        model.refreshedAt = Date()
        await model.refreshHomeOutdated(after: model.refreshedAt, environment: [:])
        XCTAssertEqual(model.homebrew?.snapshot?.outdatedPackages.count, 2)
        XCTAssertEqual(model.node?.packages.first { $0.name == "behind" }?.latestVersion, "2.0.0")
        XCTAssertEqual(model.homebrewUpdateState, .failed)
        XCTAssertEqual(model.nodeUpdateState, .failed)
        XCTAssertTrue(model.updateCards.allSatisfy { $0.primaryAction == nil && $0.versionStatus == .unknown })
    }

    func testCancelledPreparationPublishesNoConfirmationOrErrorAndReleasesOwner() async throws {
        let started = expectation(description: "npm update plan preparation started")
        let provider = FakeBatchProvider(pausedPlanName: "behind", onPlan: { started.fulfill() })
        let model = fixtureModel(provider)
        let updates = PackageUpdatesModel(model: model)
        let task = Task { await updates.prepareAll(model.updateCards, scope: .npm, subtype: .all) }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(model.operationStore.activeOperationCount, 1)
        model.operationStore.cancelActiveTask()
        await task.value
        XCTAssertNil(updates.confirmation)
        XCTAssertNil(updates.error)
        XCTAssertNil(updates.result)
        XCTAssertFalse(updates.isSubmitting)
        XCTAssertFalse(model.operationStore.hasActiveOperations)
        let names = await provider.executedNames()
        XCTAssertTrue(names.isEmpty)
    }

    func testUpdatePreviewRefusesDifferentGlobalDestinationsWithinOneEnvironment() async throws {
        let provider = FakeBatchProvider(changeDestinationAfterPlanName: "one")
        let model = fixtureModel(provider)
        let node = try XCTUnwrap(model.node)
        model.node = NodeSnapshot(summary: node.summary, configuration: node.configuration,
                                  packages: ["one", "two"].map { .init(name: $0, installedVersion: "1.0.0", wantedVersion: "1.0.0", latestVersion: "2.0.0") },
                                  installations: node.installations, managerStatus: node.managerStatus, logs: node.logs,
                                  outdatedError: nil, maintenanceError: nil)
        let updates = PackageUpdatesModel(model: model)
        await updates.prepareAll(model.updateCards, scope: .npm, subtype: .all)
        XCTAssertNil(updates.confirmation)
        XCTAssertEqual(updates.error, .staleContext)
        let names = await provider.executedNames()
        XCTAssertTrue(names.isEmpty)
        XCTAssertFalse(model.isBusy)
    }

    func testCompositeFailedRefreshRetainsPriorSnapshotAndTypedActivityOutcomes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarUpdatesActivity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let activity = ActivityStore(applicationSupportRoot: root)
        let provider = FakeBatchProvider(refreshFails: true)
        let model = fixtureModel(provider, activity: activity)
        let updates = PackageUpdatesModel(model: model)
        await updates.prepareAll(model.updateCards, scope: .all, subtype: .all)
        await updates.confirmUpdateAll()
        XCTAssertEqual(model.homebrew?.snapshot?.packages.count, 2)
        XCTAssertEqual(model.node?.packages.count, 4)
        XCTAssertEqual(model.homebrewUpdateState, .failed)
        XCTAssertEqual(model.nodeUpdateState, .failed)
        XCTAssertEqual(updates.result?.groups.map(\.refreshStatus), [.failed, .failed, .failed])
        let persistedContext = NodeEnvironmentContext(identifier: "nvm:v22.0.0", nodeVersion: context.nodeVersion, npmVersion: context.npmVersion)
        XCTAssertEqual(activity.summaries.filter { $0.operation == .update }.map(\.scope), [.npm(persistedContext), .homebrew(.cask), .homebrew(.formula)])
        XCTAssertEqual(activity.summaries.filter { $0.operation == .refresh }.count, 2)
        let persisted = try String(contentsOf: activity.fileURL, encoding: .utf8)
        for forbidden in ["TOKEN", "secret", "stdout", "/fake", "command"] { XCTAssertFalse(persisted.contains(forbidden)) }
    }

    func testPageUsesInertSharedCardsAndScopedMenuActionWithoutMetadataUpdate() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "Features/Updates/UpdatesView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("CatalogCardGrid"))
        XCTAssertTrue(source.contains(".focusedSceneValue"))
        for forbidden in ["NavigationLink", "onTapGesture", "Process(", "brew update", "planHomebrewUpdate", "Timer", "Task.sleep"] { XCTAssertFalse(source.contains(forbidden), forbidden) }
        for (language, expected) in [("en", "Update All…"), ("zh-Hans", "更新全部…"), ("zh-Hant", "更新全部…")] {
            var resource = LocalizedStringResource("Update All…")
            resource.locale = Locale(identifier: language)
            XCTAssertEqual(String(localized: resource), expected)
        }
    }

    private var context: NodeEnvironmentContext { .init(identifier: "/fake/node", nodeVersion: "v22.0.0", npmVersion: "10.0.0") }
    private func groupIntents() throws -> [BatchIntent] {
        try [BatchIntent(operation: .update, items: [.homebrew(.init(name: "formula", kind: .formula))]),
             BatchIntent(operation: .update, items: [.homebrew(.init(name: "cask", kind: .cask))]),
             BatchIntent(operation: .update, items: [.npm(.init(name: "behind", environment: context))])].map { try XCTUnwrap($0) }
    }
    private func brewSnapshot() -> HomebrewSnapshot {
        let packages = HomebrewPackageKind.allCases.map { kind in
            HomebrewPackage(identity: .init(name: "same", kind: kind), displayName: "same", description: nil, homepage: nil, installedVersions: ["1.0.0"], currentVersion: "2.0.0", tap: nil, dependencies: [], pinned: false, deprecated: false, disabled: false, artifacts: [])
        }
        return HomebrewSnapshot(executablePath: "/fake/brew", version: "5.0.0", configuration: .init(prefix: "", repository: "", cache: "", cellar: "", values: [:]), packages: packages, outdatedPackages: packages.map { .init(identity: $0.identity, installedVersions: $0.installedVersions, currentVersion: $0.currentVersion) }, taps: [], sectionErrors: [:], controlledPath: "", commandLineToolsAvailable: true)
    }
    private func nodeSnapshot() -> NodeSnapshot {
        NodeSnapshot(summary: .init(nodePath: context.identifier, npmPath: "/fake/npm", nodeVersion: context.nodeVersion, npmVersion: context.npmVersion, nvmLoaded: false, globalPrefix: "/fake", globalRoot: "/fake", registry: "https://registry.npmjs.org"), configuration: .init(registry: "", cache: "", prefix: "", userRegistry: "", projectRegistry: "", globalRegistry: ""), packages: [
            .init(name: "behind", installedVersion: "1.0.0", wantedVersion: "1.0.0", latestVersion: "2.0.0"),
            .init(name: "ahead", installedVersion: "3.0.0", wantedVersion: nil, latestVersion: "2.0.0"),
            .init(name: "unknown", installedVersion: "git", wantedVersion: nil, latestVersion: "2.0.0"),
            .init(name: "current", installedVersion: "2.0.0", wantedVersion: nil, latestVersion: "2.0.0")
        ], installations: [], managerStatus: nil, logs: [], outdatedError: nil, maintenanceError: nil)
    }
    private func fixtureModel(_ provider: FakeBatchProvider, activity: ActivityStore? = nil, outdated: HomeOutdatedDependencies? = nil) -> AppModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarUpdatesUnused-\(UUID())")
        let runner = ProcessRunner()
        let service = SystemProbeService(runner: runner, installer: ManagerSnapshotInstaller(applicationSupportDirectory: root), nodeClient: NodeManagerClient(runner: runner, environmentResolver: .init(homeDirectory: root)), shellClient: ShellManagerClient(runner: runner), environmentResolver: .init(homeDirectory: root))
        let model = AppModel(service: service, operationStore: OperationStore(), activityStore: activity, batchProvider: provider, homeOutdatedDependencies: outdated)
        let brew = brewSnapshot()
        model.homebrew = .init(executablePath: brew.executablePath, version: brew.version, managerAvailable: true, snapshot: brew)
        model.node = nodeSnapshot()
        model.homebrewUpdateState = .available
        model.nodeUpdateState = .available
        return model
    }
}
