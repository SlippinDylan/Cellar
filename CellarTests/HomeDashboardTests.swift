import Combine
import Foundation
import XCTest
@testable import Cellar

@MainActor
final class HomeDashboardTests: XCTestCase {
    func testOnlineChecksRequireLocalRefreshAndHostedTestsStayIsolated() async {
        let events = HomeTestEvents()
        let model = HomeDashboardModel(dependencies: dependencies(events: events), operationStore: OperationStore())
        await model.refresh(after: nil, environment: [:])
        await model.refresh(after: Date(), environment: ["XCTestConfigurationFilePath": "fixture"])
        let values = await events.values
        XCTAssertTrue(values.isEmpty)
        XCTAssertEqual(model.onlineVersions[.homebrew], .notLoaded)
        XCTAssertNil(model.onlineCheckedAt[.homebrew])
    }

    func testIndependentFailuresDoNotAffectOtherVersionsAndChecksRunOncePerRefresh() async {
        let events = HomeTestEvents()
        let model = HomeDashboardModel(dependencies: dependencies(events: events, failedSource: .npm), operationStore: OperationStore())
        let refresh = Date()
        await model.refresh(after: refresh, environment: [:])
        XCTAssertEqual(model.onlineVersions[.homebrew], .available(version: "5.0.0"))
        XCTAssertEqual(model.onlineVersions[.node], .available(version: "24.1.0"))
        XCTAssertEqual(model.onlineVersions[.nvm], .available(version: "0.40.0"))
        XCTAssertEqual(model.onlineVersions[.npm], .unavailable(reason: "offline"))
        XCTAssertEqual(model.commandLineTools, .available(.installed(developerDirectory: "/fixture")))
        await model.refresh(after: refresh, environment: [:])
        let values = await events.values
        XCTAssertEqual(values.filter { $0.hasPrefix("version:") }.count, 4)
        XCTAssertEqual(model.onlineCheckedAt.count, 4)
    }

    func testCancellationCancelsAllChildrenAndAllowsExplicitRestart() async {
        let started = expectation(description: "four online children started")
        started.expectedFulfillmentCount = 4
        let cancelled = expectation(description: "four online children cancelled")
        cancelled.expectedFulfillmentCount = 4
        var deps = dependencies(events: HomeTestEvents())
        deps.latestVersion = { _ in
            started.fulfill()
            do { try await Task.sleep(for: .seconds(30)); return "1.0.0" }
            catch { cancelled.fulfill(); throw error }
        }
        let model = HomeDashboardModel(dependencies: deps, operationStore: OperationStore())
        let task = Task { await model.refresh(after: Date(), environment: [:]) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await task.value
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertTrue(model.onlineVersions.values.allSatisfy { $0 == .notLoaded })
        XCTAssertTrue(model.onlineCheckedAt.isEmpty)
    }

    func testReadyOnlineVersionAndPrerequisitesAppearWhileOtherSourcesAreLoading() async {
        let available = expectation(description: "Node publishes independently")
        var deps = dependencies(events: HomeTestEvents())
        deps.latestVersion = { source in
            if source == .node { return "24.1.0" }
            try await Task.sleep(for: .seconds(30))
            return "1.0.0"
        }
        let model = HomeDashboardModel(dependencies: deps, operationStore: OperationStore())
        let subscription = model.$onlineVersions.filter { $0[.node] == .available(version: "24.1.0") }.first().sink { _ in available.fulfill() }
        let task = Task { await model.refresh(after: Date(), environment: [:]) }
        await fulfillment(of: [available], timeout: 2)
        XCTAssertEqual(model.onlineVersions[.homebrew], .loading)
        XCTAssertEqual(model.onlineVersions[.npm], .loading)
        XCTAssertEqual(model.onlineVersions[.nvm], .loading)
        task.cancel()
        await task.value
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(model.onlineVersions[.node], .available(version: "24.1.0"))
    }

    func testOccupiedHomebrewPrefixAndFailedLocalReadNeverOfferInstallation() async {
        var deps = dependencies(events: HomeTestEvents())
        deps.homebrewLocationOccupied = { true }
        let model = HomeDashboardModel(dependencies: deps, operationStore: OperationStore())
        await model.refresh(after: Date(), environment: [:])
        let missing = HomebrewStatus(executablePath: nil, version: nil, managerAvailable: true, snapshot: nil)
        guard case .unavailable = model.installationState(homebrew: missing, readFailed: false, hasRefreshed: true) else { return XCTFail("Existing Homebrew prefix must not be overwritten") }
        guard case .unavailable = model.installationState(homebrew: missing, readFailed: true, hasRefreshed: true) else { return XCTFail("A failed read cannot imply absence") }
    }

    func testInstallerLocationMustBeAbsentIncludingDirectoryEntriesAndDanglingLinks() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarHomeLocationTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(HomeDashboardDependencies.installationLocationIsClear(at: root.appending(path: "absent")))
        XCTAssertFalse(HomeDashboardDependencies.installationLocationIsClear(at: root))
        let link = root.appending(path: "dangling")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appending(path: "absent"))
        XCTAssertFalse(HomeDashboardDependencies.installationLocationIsClear(at: link))
    }

    func testPrerequisiteFailureDoesNotDiscardNVMOrOnlineVersions() async {
        var deps = dependencies(events: HomeTestEvents())
        deps.commandLineTools = { throw URLError(.badServerResponse) }
        let model = HomeDashboardModel(dependencies: deps, operationStore: OperationStore())
        await model.refresh(after: Date(), environment: [:])
        XCTAssertEqual(model.commandLineTools, .failed)
        XCTAssertEqual(model.nvmInstalled, true)
        XCTAssertEqual(model.onlineVersions[.node], .available(version: "24.1.0"))
    }

    func testHomebrewCountsAndPartialFailureDoNotBecomeEmptySuccess() {
        let snapshot = homebrewSnapshot(errors: [:])
        let summary = HomebrewDashboardSummary(snapshot: snapshot)
        XCTAssertEqual(summary.version, "5.0.0")
        XCTAssertEqual(summary.formulaCount, 2)
        XCTAssertEqual(summary.caskCount, 1)
        XCTAssertEqual(summary.updates?.totalCount, 7)
        XCTAssertEqual(summary.updates?.names, ["a", "b", "c", "d", "e"])
        let partial = HomebrewDashboardSummary(snapshot: homebrewSnapshot(errors: [.packages: "fixture", .outdated: "fixture"]))
        XCTAssertNil(partial.formulaCount)
        XCTAssertNil(partial.caskCount)
        XCTAssertNil(partial.updates)
        XCTAssertTrue(partial.hasPartialFailure)
    }

    func testNPMCountsBelongToControlledEnvironmentAndOnlyBehindIsAnUpdate() {
        let summary = NodeDashboardSummary(snapshot: nodeSnapshot())
        XCTAssertEqual(summary.nodeVersion, "v22.0.0")
        XCTAssertEqual(summary.defaultVersion, "v20.0.0")
        XCTAssertEqual(summary.packageCount, 3)
        XCTAssertEqual(summary.updates?.names, ["behind"])
        XCTAssertNil(NodeDashboardSummary(snapshot: nodeSnapshot(outdatedError: "fixture")).updates)
    }

    func testFailedLocalRefreshRetainsSuccessfulSnapshotsAndTheirTimestamps() {
        let model = AppModel.live()
        let homebrew = HomebrewStatus(executablePath: "/fixture/brew", version: "Homebrew 5.0.0", managerAvailable: true, snapshot: homebrewSnapshot(errors: [:]))
        model.applyHomebrewReadResult(.success(homebrew))
        model.applyNodeReadResult(.success(nodeSnapshot()))
        let brewTime = model.homebrewRefreshedAt
        let nodeTime = model.nodeRefreshedAt
        model.applyHomebrewReadResult(.failure(URLError(.badServerResponse)))
        model.applyNodeReadResult(.failure(URLError(.badServerResponse)))
        XCTAssertEqual(model.homebrew?.version, homebrew.version)
        XCTAssertEqual(model.node?.packages.count, 3)
        XCTAssertEqual(model.homebrewRefreshedAt, brewTime)
        XCTAssertEqual(model.nodeRefreshedAt, nodeTime)
        XCTAssertTrue(model.homebrewRefreshFailed)
        XCTAssertTrue(model.nodeRefreshFailed)
    }

    func testDelayedOutdatedQueriesPublishCoreFirstAndFailIndependently() async {
        let started = expectation(description: "both outdated providers started after core publication")
        started.expectedFulfillmentCount = 2
        let nodeFailed = expectation(description: "Node outdated fails independently")
        let gate = HomeOutdatedGate()
        let deps = HomeOutdatedDependencies(homebrew: {
            await gate.wait("homebrew", started: started)
            return [HomebrewOutdatedPackage(identity: .init(name: "new-update", kind: .formula), installedVersions: ["1.0.0"], currentVersion: "2.0.0")]
        }, node: { core in
            XCTAssertEqual(core.summary.nodeVersion, "v22.0.0")
            await gate.wait("node", started: started)
            throw URLError(.notConnectedToInternet)
        })
        let model = updateModel(dependencies: deps)
        let nodeSubscription = model.$nodeUpdateState.filter { $0 == .failed }.first().sink { _ in nodeFailed.fulfill() }
        let refreshedAt = model.refreshedAt
        let task = Task { await model.refreshHomeOutdated(after: refreshedAt, environment: [:]) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(model.homebrewUpdateState, .loading)
        XCTAssertEqual(model.nodeUpdateState, .loading)
        XCTAssertEqual(model.homebrew?.snapshot?.packages.count, 3)
        XCTAssertEqual(model.homebrew?.version, "Homebrew 5.0.0")
        XCTAssertEqual(model.node?.summary.nodeVersion, "v22.0.0")
        XCTAssertEqual(model.node?.summary.npmVersion, "10.0.0")
        XCTAssertEqual(model.node?.packages.count, 3)
        await gate.resume("node")
        await fulfillment(of: [nodeFailed], timeout: 2)
        XCTAssertEqual(model.homebrewUpdateState, .loading)
        XCTAssertEqual(model.node?.packages.count, 3)
        XCTAssertEqual(model.node?.configuration.registry, "https://fixture.invalid")
        XCTAssertNotNil(model.node?.outdatedError)
        await gate.resume("homebrew")
        await task.value
        XCTAssertEqual(model.homebrewUpdateState, .available)
        XCTAssertEqual(model.homebrew?.snapshot?.outdatedPackages.first?.identity.name, "new-update")
        XCTAssertEqual(model.homebrew?.snapshot?.packages.count, 3)
        XCTAssertEqual(model.refreshedAt, refreshedAt)
        XCTAssertFalse(model.nodeRefreshFailed)
        withExtendedLifetime(nodeSubscription) {}
    }

    func testOutdatedCancellationRestoresUncheckedStateWithoutDiscardingCore() async {
        let started = expectation(description: "both outdated reads started")
        started.expectedFulfillmentCount = 2
        let model = updateModel(dependencies: HomeOutdatedDependencies(homebrew: {
            started.fulfill()
            try await Task.sleep(for: .seconds(30))
            return []
        }, node: { _ in
            started.fulfill()
            try await Task.sleep(for: .seconds(30))
            return [:]
        }))
        let task = Task { await model.refreshHomeOutdated(after: model.refreshedAt, environment: [:]) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await task.value
        XCTAssertEqual(model.homebrewUpdateState, .notLoaded)
        XCTAssertEqual(model.nodeUpdateState, .notLoaded)
        XCTAssertEqual(model.homebrew?.snapshot?.packages.count, 3)
        XCTAssertEqual(model.node?.packages.count, 3)
        XCTAssertNil(model.homebrewOutdatedCheckedAt)
        XCTAssertNil(model.nodeOutdatedCheckedAt)
    }

    func testQuickReturnThenCancellationDoesNotRetainAnObsoleteLoadingState() async {
        let firstStarted = expectation(description: "first visit started both reads")
        firstStarted.expectedFulfillmentCount = 2
        let secondStarted = expectation(description: "second visit started both reads")
        secondStarted.expectedFulfillmentCount = 2
        let events = HomeTestEvents()
        let gate = HomeOutdatedGate()
        let model = updateModel(dependencies: HomeOutdatedDependencies(homebrew: {
            let attempt = await events.nextCall("brew")
            await gate.wait("brew-\(attempt)", started: attempt == 0 ? firstStarted : secondStarted)
            return []
        }, node: { _ in
            let attempt = await events.nextCall("npm")
            await gate.wait("npm-\(attempt)", started: attempt == 0 ? firstStarted : secondStarted)
            return [:]
        }))
        let first = Task { await model.refreshHomeOutdated(after: model.refreshedAt, environment: [:]) }
        await fulfillment(of: [firstStarted], timeout: 2)
        first.cancel()
        let second = Task { await model.refreshHomeOutdated(after: model.refreshedAt, environment: [:]) }
        await fulfillment(of: [secondStarted], timeout: 2)
        second.cancel()
        await gate.resume("brew-1")
        await gate.resume("npm-1")
        await second.value
        XCTAssertEqual(model.homebrewUpdateState, .notLoaded)
        XCTAssertEqual(model.nodeUpdateState, .notLoaded)
        await gate.resume("brew-0")
        await gate.resume("npm-0")
        await first.value
        XCTAssertEqual(model.homebrewUpdateState, .notLoaded)
        XCTAssertEqual(model.nodeUpdateState, .notLoaded)
    }

    func testHomebrewOutdatedFailureKeepsCoreAndNPMResultsAndChecksDoNotPoll() async {
        let events = HomeTestEvents()
        let model = updateModel(dependencies: HomeOutdatedDependencies(homebrew: {
            await events.record("brew-outdated")
            throw URLError(.notConnectedToInternet)
        }, node: { _ in
            await events.record("npm-outdated")
            return ["behind": OutdatedPackage(current: "1.0.0", wanted: "1.0.0", latest: "2.0.0")]
        }))
        await model.refreshHomeOutdated(after: model.refreshedAt, environment: [:])
        XCTAssertEqual(model.homebrewUpdateState, .failed)
        XCTAssertEqual(model.nodeUpdateState, .available)
        XCTAssertEqual(model.homebrew?.snapshot?.packages.count, 3)
        XCTAssertEqual(model.homebrew?.snapshot?.configuration.values, [:])
        XCTAssertNotNil(model.homebrew?.snapshot?.sectionErrors[.outdated])
        XCTAssertEqual(model.node?.packages.first?.latestVersion, "2.0.0")
        await model.refreshHomeOutdated(after: model.refreshedAt, environment: [:])
        let recorded = await events.values
        XCTAssertEqual(recorded.sorted(), ["brew-outdated", "npm-outdated"])
    }

    func testHomeOutdatedChecksAreIsolatedInHostedTests() async {
        let model = updateModel(dependencies: HomeOutdatedDependencies(homebrew: {
            XCTFail("Hosted views must not call brew outdated"); return []
        }, node: { _ in
            XCTFail("Hosted views must not call npm outdated"); return [:]
        }))
        await model.refreshHomeOutdated(after: model.refreshedAt)
        XCTAssertEqual(model.homebrewUpdateState, .notLoaded)
        XCTAssertEqual(model.nodeUpdateState, .notLoaded)
    }

    func testSetupOnlyRunsExplicitEligibleActionsAndHandoffMustFinishBeforeAnotherOpen() async {
        let events = HomeTestEvents()
        let operations = OperationStore()
        let model = HomeDashboardModel(dependencies: dependencies(events: events), operationStore: operations)
        await model.openHomebrewInstaller(installation: .notChecked)
        await model.openHomebrewInstaller(installation: .unavailable(reason: "corrupt"))
        let initiallyEmpty = await events.isEmpty()
        XCTAssertTrue(initiallyEmpty)
        await model.openHomebrewInstaller(installation: .notInstalled)
        XCTAssertEqual(model.setupState, .installerOpened)
        XCTAssertFalse(operations.hasActiveOperations)
        await model.openHomebrewInstaller(installation: .notInstalled)
        let openCount = await events.count("open")
        XCTAssertEqual(openCount, 1)
        let finished = await model.finishInstallerHandoff()
        XCTAssertTrue(finished)
        XCTAssertEqual(model.setupState, .idle)
        let finishCount = await events.count("finish")
        XCTAssertEqual(finishCount, 1)
        await model.requestCommandLineTools(installation: .commandLineToolsRequired)
        XCTAssertEqual(model.setupState, .commandLineToolsRequested)
        let requestCount = await events.count("clt-install")
        XCTAssertEqual(requestCount, 1)
    }

    func testSetupFailureRetainsStructuredCauseAndOfficialRecoveryLink() async {
        var deps = dependencies(events: HomeTestEvents())
        deps.openInstaller = { throw HomebrewSetupError(failure: .gatekeeper) }
        let model = HomeDashboardModel(dependencies: deps, operationStore: OperationStore())
        await model.openHomebrewInstaller(installation: .notInstalled)
        XCTAssertEqual(model.setupState, .failed(.homebrew(.gatekeeper)))
        XCTAssertEqual(model.officialHomebrewURL, CatalogWebsites.homebrew)
    }

    func testUpdatePreviewKeepsExactNamesAndLimitsThePreview() {
        let preview = HomeUpdatePreview(names: ["f", "b", "a", "g", "d", "c", "e"])
        XCTAssertEqual(preview.names, ["a", "b", "c", "d", "e"])
        XCTAssertEqual(preview.totalCount, 7)
        XCTAssertEqual(preview.remainingCount, 2)
        XCTAssertEqual(HomeUpdatePreview(names: []).remainingCount, 0)
    }

    func testHomeSourceExcludesTechnicalContentAndOwnsCancellableViewTasks() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let home = try String(contentsOf: root.appending(path: "Features/Home/HomeView.swift"), encoding: .utf8)
        let appModel = try String(contentsOf: root.appending(path: "Services/AppModel.swift"), encoding: .utf8)
        let shell = try String(contentsOf: root.appending(path: "Features/AppRootView.swift"), encoding: .utf8)
        for forbidden in ["Oh My Zsh", "zshrc", "executablePath", "managerStatus", "model.shell", "model.managers", "Timer", "Task.detached", "Process("] {
            XCTAssertFalse(home.contains(forbidden), forbidden)
        }
        XCTAssertTrue(home.contains(".task(id: model.isRefreshing ? nil : model.refreshedAt)"))
        XCTAssertTrue(home.contains(".task(id: setupRequest)"))
        XCTAssertTrue(home.contains("model.refreshHomeOutdated(after:"))
        XCTAssertTrue(appModel.contains("service.loadHomebrew(snapshot: snapshot, includingOutdated: false)"))
        XCTAssertTrue(appModel.contains("preferredNodeVersion: self.preferredNodeVersion, includingOutdated: false"))
        XCTAssertTrue(shell.contains("HomeView(model: model)"))
    }

    private func dependencies(events: HomeTestEvents, failedSource: HomeOnlineSource? = nil) -> HomeDashboardDependencies {
        HomeDashboardDependencies(
            commandLineTools: { .installed(developerDirectory: "/fixture") },
            nvmInstalled: { true },
            latestVersion: { source in
                await events.record("version:\(source.rawValue)")
                if source == failedSource { throw URLError(.notConnectedToInternet) }
                switch source {
                case .homebrew: return "5.0.0"
                case .node: return "24.1.0"
                case .npm: return "11.1.0"
                case .nvm: return "0.40.0"
                }
            },
            requestCommandLineTools: { await events.record("clt-install") },
            openInstaller: { await events.record("open") },
            finishInstallerHandoff: { await events.record("finish") }
        )
    }

    private func homebrewSnapshot(errors: [HomebrewSnapshot.Section: String]) -> HomebrewSnapshot {
        let packages = [HomebrewPackageKind.formula, .formula, .cask].enumerated().map { index, kind in
            HomebrewPackage(identity: .init(name: "item\(index)", kind: kind), displayName: "item\(index)", description: nil, homepage: nil, installedVersions: ["1.0.0"], currentVersion: "1.0.0", tap: nil, dependencies: [], pinned: false, deprecated: false, disabled: false, artifacts: [])
        }
        return HomebrewSnapshot(executablePath: "/fixture/brew", version: "Homebrew 5.0.0", configuration: HomebrewConfiguration(prefix: "", repository: "", cache: "", cellar: "", values: [:]), packages: packages, outdatedPackages: ["g", "c", "a", "f", "b", "e", "d"].map { HomebrewOutdatedPackage(identity: .init(name: $0, kind: .formula), installedVersions: ["1.0.0"], currentVersion: "2.0.0") }, taps: [], sectionErrors: errors, controlledPath: "/fixture", commandLineToolsAvailable: true)
    }

    private func nodeSnapshot(outdatedError: String? = nil) -> NodeSnapshot {
        NodeSnapshot(summary: NodeSummary(nodePath: "/fixture/node", npmPath: "/fixture/npm", nodeVersion: "v22.0.0", npmVersion: "10.0.0", nvmLoaded: true, globalPrefix: "/fixture", globalRoot: "/fixture", registry: "https://fixture.invalid"), configuration: NodeConfiguration(registry: "https://fixture.invalid", cache: "/fixture", prefix: "/fixture", userRegistry: "", projectRegistry: "", globalRegistry: ""), packages: [
            NodePackageRow(name: "behind", installedVersion: "1.0.0", wantedVersion: nil, latestVersion: "2.0.0"),
            NodePackageRow(name: "ahead", installedVersion: "3.0.0", wantedVersion: nil, latestVersion: "2.0.0"),
            NodePackageRow(name: "unknown", installedVersion: "latest", wantedVersion: nil, latestVersion: "2.0.0")
        ], installations: [NodeInstallation(version: "v20.0.0", directory: "/fixture/node20", isActive: false, isDefault: true), NodeInstallation(version: "v22.0.0", directory: "/fixture/node22", isActive: true, isDefault: false)], managerStatus: nil, logs: [], outdatedError: outdatedError, maintenanceError: nil)
    }

    private func updateModel(dependencies updateDependencies: HomeOutdatedDependencies) -> AppModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarHomeUpdatesTests-\(UUID())")
        let runner = ProcessRunner()
        let resolver = NodeEnvironmentResolver(homeDirectory: root)
        let service = SystemProbeService(runner: runner, installer: ManagerSnapshotInstaller(applicationSupportDirectory: root),
                                         nodeClient: NodeManagerClient(runner: runner, environmentResolver: resolver),
                                         shellClient: ShellManagerClient(runner: runner, environmentResolver: ShellEnvironmentResolver(homeDirectory: root)),
                                         environmentResolver: resolver)
        let model = AppModel(service: service, operationStore: OperationStore(), homeDashboardDependencies: dependencies(events: HomeTestEvents()),
                             homeOutdatedDependencies: updateDependencies)
        let core = homebrewSnapshot(errors: [:]).replacingOutdated(packages: [], error: nil)
        model.applyHomebrewReadResult(.success(HomebrewStatus(executablePath: "/fixture/brew", version: core.version, managerAvailable: true, snapshot: core)))
        model.applyNodeReadResult(.success(nodeSnapshot().replacingOutdated(packages: [:], error: nil)))
        model.refreshedAt = Date()
        return model
    }
}

private actor HomeTestEvents {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
    func isEmpty() -> Bool { values.isEmpty }
    func count(_ value: String) -> Int { values.filter { $0 == value }.count }
    func nextCall(_ value: String) -> Int {
        let index = values.filter { $0 == value }.count
        values.append(value)
        return index
    }
}

private actor HomeOutdatedGate {
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    func wait(_ provider: String, started: XCTestExpectation) async {
        await withCheckedContinuation { continuation in
            waiters[provider] = continuation
            started.fulfill()
        }
    }
    func resume(_ provider: String) {
        guard let waiter = waiters.removeValue(forKey: provider) else { preconditionFailure("Expected a waiting fake provider") }
        waiter.resume()
    }
}
