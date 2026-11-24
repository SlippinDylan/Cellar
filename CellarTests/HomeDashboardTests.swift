import AppKit
import Combine
import Darwin
import Foundation
import XCTest
@testable import Cellar

@MainActor
final class HomeDashboardTests: XCTestCase {
    func testSetupRequestsPersistHandoffSemanticsAndFiniteTrustFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarSetupActivity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let activity = ActivityStore()
        var deps = dependencies(events: HomeTestEvents())
        deps.openInstaller = { throw HomebrewSetupError(failure: .packageSignature) }
        let model = HomeDashboardModel(dependencies: deps, operationStore: OperationStore(), activityStore: activity)
        await model.requestCommandLineTools(installation: .commandLineToolsRequired)
        XCTAssertEqual(activity.summaries.first?.operation, .requestCommandLineTools)
        XCTAssertEqual(activity.summaries.first?.status, .succeeded)
        await model.openHomebrewInstaller(installation: .notInstalled)
        XCTAssertEqual(activity.summaries.first?.operation, .openHomebrewInstaller)
        XCTAssertEqual(activity.summaries.first?.status, .failed)
        XCTAssertEqual(activity.summaries.first?.reason, .stateUnavailable)
    }

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

    func testPrerequisiteFailureDoesNotDiscardOnlineVersions() async {
        var deps = dependencies(events: HomeTestEvents())
        deps.commandLineTools = { throw URLError(.badServerResponse) }
        let model = HomeDashboardModel(dependencies: deps, operationStore: OperationStore())
        await model.refresh(after: Date(), environment: [:])
        XCTAssertEqual(model.commandLineTools, .failed)
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

    func testHomeVersionDisplayOnlyShowsLatestWhenAnUpdateIsAvailable() {
        XCTAssertEqual(HomeVersion.display(current: "v26.0.0", online: .available(version: "26.0.0")), "26.0.0")
        XCTAssertEqual(HomeVersion.display(current: "11.19.1", online: .available(version: "12.2.0")), "11.19.1 → 12.2.0")
        XCTAssertTrue(HomeVersion.hasUpdate(current: "11.19.1", online: .available(version: "12.2.0")))
        XCTAssertEqual(HomeVersion.display(current: "Homebrew 7.0.7", online: .available(version: "6.0.0")), "7.0.7")
        XCTAssertFalse(HomeVersion.hasUpdate(current: "Homebrew 7.0.7", online: .available(version: "6.0.0")))
        XCTAssertEqual(HomeVersion.display(current: "7.0.7", online: .loading), "7.0.7")
        XCTAssertEqual(HomeVersion.display(current: "7.0.7", online: .unavailable(reason: "offline")), "7.0.7")
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

    func testInvalidatedHomeUpdatesThenFailedCoreReadSettlesProgress() async {
        let started = expectation(description: "obsolete reads are gated")
        started.expectedFulfillmentCount = 2
        let gate = HomeOutdatedGate()
        let model = updateModel(dependencies: HomeOutdatedDependencies(homebrew: {
            await gate.wait("brew", started: started)
            return []
        }, node: { _ in
            await gate.wait("npm", started: started)
            return [:]
        }))
        let first = Task { await model.refreshHomeOutdated(after: model.refreshedAt, environment: [:]) }
        await fulfillment(of: [started], timeout: 2)
        // Reproduce the invalidation performed when a new core refresh begins.
        model.invalidateHomeUpdates()
        XCTAssertEqual(model.homebrewUpdateState, .notLoaded)
        XCTAssertEqual(model.nodeUpdateState, .notLoaded)
        model.applyHomebrewReadResult(.failure(URLError(.badServerResponse)))
        model.applyNodeReadResult(.failure(URLError(.badServerResponse)))
        model.refreshedAt = Date()
        await model.refreshHomeOutdated(after: model.refreshedAt, environment: [:])
        XCTAssertEqual(model.homebrewUpdateState, .failed)
        XCTAssertEqual(model.nodeUpdateState, .failed)
        await gate.resume("brew")
        await gate.resume("npm")
        await first.value
        XCTAssertEqual(model.homebrewUpdateState, .failed)
        XCTAssertEqual(model.nodeUpdateState, .failed)
        XCTAssertEqual(model.homebrew?.snapshot?.packages.count, 3)
        XCTAssertEqual(model.node?.packages.count, 3)
    }

    func testHomeBackgroundIsRegisteredCancellableAndProtectsTerminationWhileProcessRuns() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarHomeLifecycleTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appending(path: "started.fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let script = root.appending(path: "gated-provider.sh")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$$\" > \"$1/started.fifo\"\nexec /bin/sleep 30\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let pidReader = Task.detached { () throws -> pid_t in
            let file = try FileHandle(forReadingFrom: fifo)
            defer { try? file.close() }
            let data = try XCTUnwrap(file.readToEnd())
            return try XCTUnwrap(Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        let readersStarted = expectation(description: "Node and four metadata reads started")
        readersStarted.expectedFulfillmentCount = 5
        let readersCancelled = expectation(description: "Node and four metadata reads cancelled")
        readersCancelled.expectedFulfillmentCount = 5
        var dashboard = dependencies(events: HomeTestEvents())
        dashboard.latestVersion = { _ in
            readersStarted.fulfill()
            do { try await Task.sleep(for: .seconds(30)); return "1.0.0" }
            catch { readersCancelled.fulfill(); throw error }
        }
        let runner = ProcessRunner()
        let model = updateModel(dependencies: HomeOutdatedDependencies(homebrew: {
            _ = try await runner.run(ProcessRequest(executableURL: script, arguments: [root.path],
                                                    environment: ["HOME": root.path, "PATH": "/usr/bin:/bin"],
                                                    currentDirectoryURL: root, timeout: .seconds(30)))
            return []
        }, node: { _ in
            readersStarted.fulfill()
            do { try await Task.sleep(for: .seconds(30)); return [:] }
            catch { readersCancelled.fulfill(); throw error }
        }), dashboardDependencies: dashboard)
        let suite = "Cellar.HomeLifecycleTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let relaunch = ApplicationRelaunchController(operationStore: model.operationStore, defaults: defaults,
                                                    defaultsDomainName: suite, terminateApplication: {})
        let terminationReplied = expectation(description: "Termination waits until read-only child processes exit")
        let delegate = AppDelegate(operationStore: model.operationStore, relaunchController: relaunch, replyToTermination: { allowed in
            XCTAssertTrue(allowed)
            terminationReplied.fulfill()
        }, reopenApplication: {})
        XCTAssertEqual(model.homebrew?.version, "Homebrew 5.0.0")
        XCTAssertEqual(model.node?.packages.count, 3)
        let task = Task { await model.refreshHomeBackground(after: model.refreshedAt, environment: [:]) }
        let pid = try await pidReader.value
        await fulfillment(of: [readersStarted], timeout: 2)
        XCTAssertEqual(kill(pid, 0), 0)
        XCTAssertFalse(model.operationStore.hasActiveOperations)
        XCTAssertTrue(model.operationStore.hasActiveReadOnlyOperations)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertTrue(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        await fulfillment(of: [terminationReplied], timeout: 5)
        XCTAssertEqual(kill(pid, 0), -1, "Child process must already be reaped before termination reply")
        await task.value
        await fulfillment(of: [readersCancelled], timeout: 2)
        XCTAssertFalse(model.operationStore.hasActiveOperations)
        XCTAssertFalse(model.operationStore.hasActiveReadOnlyOperations)
        XCTAssertEqual(model.operationStore.activeOperationCount, 0)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertEqual(model.homebrewUpdateState, .notLoaded)
        XCTAssertEqual(model.nodeUpdateState, .notLoaded)
        XCTAssertTrue(model.homeDashboard.onlineVersions.values.allSatisfy { $0 == .notLoaded })
    }

    func testHomeInstallActionRevalidatesCurrentCLTAndTargetBeforeOpening() async {
        for missingTools in [true, false] {
            let events = HomeTestEvents()
            var deps = dependencies(events: events)
            deps.commandLineTools = { missingTools ? .notInstalled : .installed(developerDirectory: "/fixture") }
            deps.homebrewLocationOccupied = { !missingTools }
            let model = HomeDashboardModel(dependencies: deps, operationStore: OperationStore())
            await model.openHomebrewInstaller(installation: .notInstalled)
            let count = await events.count("open")
            XCTAssertEqual(count, 0)
            XCTAssertEqual(model.setupState, .failed(.homebrew(missingTools ? .commandLineToolsRequired : .installationTarget)))
            XCTAssertFalse(model.installerHandoffPending)
        }
    }

    func testHomeBackgroundCompletesAndHostedOrRepeatedCallsDoNotLeaveAnActiveSlot() async {
        let events = HomeTestEvents()
        let model = updateModel(dependencies: HomeOutdatedDependencies(homebrew: {
            await events.record("brew-outdated"); return []
        }, node: { _ in
            await events.record("npm-outdated"); return [:]
        }), dashboardDependencies: dependencies(events: events))
        await model.refreshHomeBackground(after: nil, environment: [:])
        await model.refreshHomeBackground(after: model.refreshedAt)
        let before = await events.values
        XCTAssertTrue(before.isEmpty)
        XCTAssertEqual(model.operationStore.activeOperationCount, 0)
        await model.refreshHomeBackground(after: model.refreshedAt, environment: [:])
        await model.refreshHomeBackground(after: model.refreshedAt, environment: [:])
        let recorded = await events.values
        XCTAssertEqual(recorded.count, 6)
        XCTAssertEqual(model.operationStore.activeOperationCount, 0)
        XCTAssertEqual(AppTerminationPolicy.reply(hasActiveOperations: model.operationStore.hasActiveOperations), .terminateNow)
    }

    func testReturningHomeDuringPriorCancellationCleanupTakesOverExactlyOnce() async {
        await assertHomeBackgroundTakeover(cancelFirst: true, cancelReplacement: false, unrelatedOperation: false)
    }

    func testReplacementCallerCancelledBeforeTakeoverStartsNoChecks() async {
        await assertHomeBackgroundTakeover(cancelFirst: true, cancelReplacement: true, unrelatedOperation: false)
    }

    func testUnrelatedOperationWinningTheSlotPreventsDeferredHomeChecks() async {
        await assertHomeBackgroundTakeover(cancelFirst: true, cancelReplacement: false, unrelatedOperation: true)
    }

    func testOverlappingDuplicateHomeCallsDoNotCancelOrRestartHealthyChecks() async {
        await assertHomeBackgroundTakeover(cancelFirst: false, cancelReplacement: false, unrelatedOperation: false)
    }

    private func assertHomeBackgroundTakeover(cancelFirst: Bool, cancelReplacement: Bool, unrelatedOperation: Bool) async {
        let keys = ["brew", "npm"] + HomeOnlineSource.allCases.map { "version:\($0.rawValue)" }
        let started = expectation(description: "all six first-owner reads are waiting")
        started.expectedFulfillmentCount = keys.count
        let cleanup = XCTestExpectation(description: "all six reads received cancellation but retain cleanup")
        cleanup.expectedFulfillmentCount = keys.count
        let arrived = expectation(description: "replacement caller entered Home")
        let events = HomeTestEvents()
        let gate = HomeOutdatedGate()
        let read: @Sendable (String) async throws -> Void = { key in
            let attempt = await events.nextCall(key)
            if attempt == 0 {
                await withTaskCancellationHandler {
                    await gate.wait(key, started: started)
                } onCancel: { cleanup.fulfill() }
                try Task.checkCancellation()
            }
        }
        var dashboard = dependencies(events: events)
        dashboard.latestVersion = { source in
            try await read("version:\(source.rawValue)")
            return "2.0.0"
        }
        let model = updateModel(dependencies: HomeOutdatedDependencies(homebrew: {
            try await read("brew")
            return [HomebrewOutdatedPackage(identity: .init(name: "current-result", kind: .formula), installedVersions: ["1.0.0"], currentVersion: "2.0.0")]
        }, node: { _ in
            try await read("npm")
            return ["behind": OutdatedPackage(current: "1.0.0", wanted: "1.0.0", latest: "2.0.0")]
        }), dashboardDependencies: dashboard)
        let refresh = model.refreshedAt
        let first = Task { await model.refreshHomeBackground(after: refresh, environment: [:]) }
        await fulfillment(of: [started], timeout: 2)
        if cancelFirst {
            first.cancel()
            await fulfillment(of: [cleanup], timeout: 2)
        }
        XCTAssertEqual(model.operationStore.activeOperationCount, 0)
        XCTAssertTrue(model.operationStore.hasActiveReadOnlyOperations)
        XCTAssertEqual(AppTerminationPolicy.reply(hasActiveOperations: model.operationStore.hasActiveOperations), .terminateNow)
        let replacement = Task {
            arrived.fulfill()
            await model.refreshHomeBackground(after: refresh, environment: [:])
        }
        await fulfillment(of: [arrived], timeout: 2)
        if cancelReplacement { replacement.cancel() }
        let unrelatedID = unrelatedOperation ? model.operationStore.begin() : nil
        for key in keys { await gate.resume(key) }
        await first.value
        await replacement.value
        let takesOver = cancelFirst && !cancelReplacement && !unrelatedOperation
        for key in keys {
            let count = await events.count(key)
            XCTAssertEqual(count, takesOver ? 2 : 1, key)
        }
        if takesOver || !cancelFirst {
            XCTAssertEqual(model.homebrewUpdateState, .available)
            XCTAssertEqual(model.nodeUpdateState, .available)
            XCTAssertEqual(model.homebrew?.snapshot?.outdatedPackages.first?.identity.name, "current-result")
            XCTAssertEqual(model.node?.packages.first?.latestVersion, "2.0.0")
            XCTAssertTrue(model.homeDashboard.onlineVersions.values.allSatisfy { $0 == .available(version: "2.0.0") })
        } else {
            XCTAssertEqual(model.homebrewUpdateState, .notLoaded)
            XCTAssertEqual(model.nodeUpdateState, .notLoaded)
        }
        XCTAssertEqual(model.homebrew?.snapshot?.packages.count, 3)
        XCTAssertEqual(model.node?.packages.count, 3)
        if let unrelatedID {
            XCTAssertEqual(model.operationStore.activeOperationCount, 1)
            model.operationStore.end(unrelatedID)
        }
        XCTAssertEqual(model.operationStore.activeOperationCount, 0)
        if takesOver {
            await model.refreshHomeBackground(after: refresh, environment: [:])
            for key in keys {
                let count = await events.count(key)
                XCTAssertEqual(count, 2, "Completed checks must not restart: \(key)")
            }
        }
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

    func testHomeSourceKeepsTechnicalDetailsOutAndOwnsCancellableViewTasks() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let home = try String(contentsOf: root.appending(path: "Features/Home/HomeView.swift"), encoding: .utf8)
        let appModel = try String(contentsOf: root.appending(path: "Services/AppModel.swift"), encoding: .utf8)
        let shell = try String(contentsOf: root.appending(path: "Features/AppRootView.swift"), encoding: .utf8)
        for forbidden in ["zshrc", "executablePath", "managerStatus", "model.managers", "Timer", "Task.detached", "Process("] {
            XCTAssertFalse(home.contains(forbidden), forbidden)
        }
        XCTAssertTrue(home.contains("Oh My Zsh"))
        XCTAssertTrue(home.contains("model.shell"))
        XCTAssertTrue(home.contains(".task(id: model.isRefreshing ? nil : model.refreshedAt)"))
        XCTAssertTrue(home.contains(".task(id: setupRequest)"))
        XCTAssertTrue(home.contains("model.refreshHomeBackground(after:"))
        XCTAssertTrue(appModel.contains("service.loadHomebrew(snapshot: snapshot, includingOutdated: false)"))
        XCTAssertTrue(appModel.contains("preferredNodeVersion: self.preferredNodeVersion, includingOutdated: false"))
        XCTAssertTrue(shell.contains("HomeView(model: model)"))
    }

    func testHomeStacksProviderSectionsAndUsesIndependentMetricCards() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let home = try String(contentsOf: root.appending(path: "Features/Home/HomeView.swift"), encoding: .utf8)

        XCTAssertFalse(home.contains("StatusMetricDivider"))
        XCTAssertEqual(home.components(separatedBy: "isStandaloneCard: true").count - 1, 13)
        XCTAssertTrue(home.contains("homebrewSection\n                nodeSection\n                terminalEnvironmentSection"))
        XCTAssertTrue(home.contains("private func homebrewMetrics"))
        XCTAssertTrue(home.contains("private func nodeMetrics(_ summary: NodeDashboardSummary?)"))
        XCTAssertTrue(home.contains("private var terminalEnvironmentMetrics"))
        XCTAssertTrue(home.contains("nodeMetrics(model.node.map(NodeDashboardSummary.init))"))
        XCTAssertEqual(home.components(separatedBy: "StatusMetric(").count - 1, 13)
        XCTAssertEqual(home.components(separatedBy: "valueSystemImage:").count - 1, 3)
        XCTAssertTrue(home.contains("titleLink: dashboard.officialHomebrewURL"))
        XCTAssertTrue(home.contains("systemImage: \"app.grid\""))
        XCTAssertFalse(home.contains("GroupBox"))
        XCTAssertTrue(home.contains("Label(\"Node\", systemImage: \"shippingbox\")"))
        XCTAssertFalse(home.contains("Node, npm & nvm"))
        XCTAssertFalse(home.contains("HomeOnlineVersionRow"))
        XCTAssertFalse(home.contains("HomeTimestampRow"))
        XCTAssertFalse(home.contains("Open Environment Setup"))
        XCTAssertFalse(home.contains("Open Runtime Tools"))
    }

    func testHomeImagesLoadFromTheAppBundle() throws {
        for name in ["HomebrewBrand", "NodeBrand", "NPMBrand", "NVMBrand", "ZshBrand", "OhMyZshBrand",
                     "FormulaIcon", "CaskIcon", "UpdatesIcon", "GlobalPackagesIcon", "NVMDefaultIcon", "CommandLineToolsIcon"] {
            let image = try XCTUnwrap(NSImage(named: name), "Missing brand asset: \(name)")
            XCTAssertGreaterThan(image.size.width, 0)
            XCTAssertGreaterThan(image.size.height, 0)
            XCTAssertFalse(image.isTemplate, "Brand colors must be preserved: \(name)")
        }
        XCTAssertNotNil(Bundle.main.url(forResource: "BrandIcons-LICENSE", withExtension: "txt"))
    }

    private func dependencies(events: HomeTestEvents, failedSource: HomeOnlineSource? = nil) -> HomeDashboardDependencies {
        HomeDashboardDependencies(
            commandLineTools: { .installed(developerDirectory: "/fixture") },
            homebrewLocationOccupied: { false },
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

    private func updateModel(dependencies updateDependencies: HomeOutdatedDependencies, dashboardDependencies: HomeDashboardDependencies? = nil) -> AppModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarHomeUpdatesTests-\(UUID())")
        let runner = ProcessRunner()
        let resolver = NodeEnvironmentResolver(homeDirectory: root)
        let service = SystemProbeService(runner: runner, installer: ManagerSnapshotInstaller(applicationSupportDirectory: root),
                                         nodeClient: NodeManagerClient(runner: runner, environmentResolver: resolver),
                                         shellClient: ShellManagerClient(runner: runner, environmentResolver: ShellEnvironmentResolver(homeDirectory: root)),
                                         environmentResolver: resolver)
        let model = AppModel(service: service, operationStore: OperationStore(), homeDashboardDependencies: dashboardDependencies ?? dependencies(events: HomeTestEvents()),
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
