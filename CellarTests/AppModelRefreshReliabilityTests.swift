import XCTest
@testable import Cellar

@MainActor
final class AppModelRefreshReliabilityTests: XCTestCase {
    func testRecoveredCleanupFactsSurviveFailedPostflightAndBlockStaleNodeWrites() async throws {
        let fixture = try NodeRefreshFixture()
        defer { fixture.remove() }
        let store = ActivityStore()
        let model = makeModel(root: fixture.root, managers: fixture.managers, activityStore: store)
        let initial = try await model.service.loadNode(snapshot: fixture.managers)
        model.applyNodeReadResult(.success(initial))
        let readTime = model.nodeRefreshedAt
        try Data().write(to: fixture.root.appending(path: "fail-after-execute"))
        let items: [NodeCleanupItem] = [.init(path: "/fixture/removed", status: .removed, reason: .removed),
                                        .init(path: "/fixture/failed", status: .failed, reason: .deletionFailed),
                                        .init(path: "/fixture/unattempted", status: .notAttempted, reason: .previousFailure)]
        let payload = try JSONDecoder().decode(NodeActionPlanPayload.self, from: Data(#"{"action":"cleanup","executeSupported":true,"executable":true,"paths":["/fixture/removed","/fixture/failed","/fixture/unattempted"]}"#.utf8))
        model.nodePlan = .init(id: UUID(), request: NodeMaintenanceAction.orphanBins.request, payload: payload, generatedAt: Date())
        await model.executeNodePlan()
        let result = try XCTUnwrap(model.nodeActionResult)
        XCTAssertEqual(result.operation.cleanupItems, items)
        XCTAssertEqual(result.operation.batchItemStatus, .partiallySucceeded)
        XCTAssertNotNil(result.postflightError)
        XCTAssertNil(result.snapshot)
        XCTAssertEqual(store.latestResult?.cleanupItems, items)
        XCTAssertEqual(store.latestResult?.status, .partiallySucceeded)
        XCTAssertTrue(model.nodeRefreshFailed)
        XCTAssertEqual(model.nodeUpdateState, .failed)
        XCTAssertEqual(model.node?.summary.nodeVersion, initial.summary.nodeVersion)
        XCTAssertEqual(model.nodeRefreshedAt, readTime)
        XCTAssertFalse(model.isBusy)
        await model.prepareNodeAction(NodeMaintenanceAction.orphanBins.request)
        XCTAssertNil(model.nodePlan)
        XCTAssertEqual(model.nodeActionResult?.operation.cleanupItems, items)
        XCTAssertEqual(store.latestResult?.cleanupItems, items)
        let calls = try String(contentsOf: fixture.root.appending(path: "calls"), encoding: .utf8)
        XCTAssertEqual(calls.split(separator: "\n").filter { $0 == "execute" }.count, 1)
    }

    func testFailedHomebrewSectionsRetainPriorValuesAndBlockMutationUntilRecovery() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        let model = makeModel(root: fixture.directoryURL, homebrew: fixture.client)
        try await readHomebrew(fixture, into: model)
        let prior = try XCTUnwrap(model.homebrew?.snapshot)
        let readTime = model.homebrewRefreshedAt
        for section in ["configuration", "packages", "taps"] {
            try Data().write(to: fixture.directoryURL.appending(path: "fail-\(section)"))
        }
        try await readHomebrew(fixture, into: model)
        let stale = try XCTUnwrap(model.homebrew?.snapshot)
        XCTAssertEqual(stale.configuration.prefix, prior.configuration.prefix)
        XCTAssertEqual(stale.packages.map(\.identity), prior.packages.map(\.identity))
        XCTAssertEqual(stale.taps.map(\.name), prior.taps.map(\.name))
        XCTAssertEqual(Set(stale.sectionErrors.keys), [.configuration, .packages, .taps])
        XCTAssertFalse(model.homebrewRefreshFailed)
        XCTAssertEqual(model.homebrewRefreshedAt, readTime)
        let intent = try XCTUnwrap(BatchIntent(operation: .uninstall, items: [.homebrew(prior.packages[0].identity)]))
        do {
            _ = try await model.prepareBatch(intent)
            XCTFail("A retained inventory cannot authorize mutation")
        } catch BatchOperationError.reconciliationUnavailable {}
        for section in ["configuration", "packages", "taps"] {
            try FileManager.default.removeItem(at: fixture.directoryURL.appending(path: "fail-\(section)"))
        }
        try await readHomebrew(fixture, into: model)
        XCTAssertFalse(model.homebrewRefreshFailed)
        XCTAssertTrue(try XCTUnwrap(model.homebrew?.snapshot).sectionErrors.isEmpty)
        XCTAssertNotEqual(model.homebrewRefreshedAt, readTime)
    }

    func testFailedInitialHomebrewSectionHasNoInventedPriorInventory() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.directoryURL.appending(path: "fail-packages"))
        let model = makeModel(root: fixture.directoryURL, homebrew: fixture.client)
        try await readHomebrew(fixture, into: model)
        XCTAssertFalse(model.homebrewRefreshFailed)
        XCTAssertNil(model.homebrewRefreshedAt)
        XCTAssertEqual(model.homebrew?.snapshot?.packages.count, 0)
        XCTAssertNotNil(model.homebrew?.snapshot?.sectionErrors[.packages])
        XCTAssertEqual(model.homebrew?.snapshot?.taps.count, 1)
    }

    func testHomebrewDirectPostreadRetainsFailedSectionsAndThenRecovers() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        let model = makeModel(root: fixture.directoryURL, homebrew: fixture.client)
        try await readHomebrew(fixture, into: model)
        let prior = try XCTUnwrap(model.homebrew?.snapshot)
        let readTime = model.homebrewRefreshedAt
        let plan = try await fixture.client.planUpdate()
        try Data().write(to: fixture.directoryURL.appending(path: "fail-packages"))
        model.homebrewPlan = plan
        await model.executeHomebrewPlan()
        XCTAssertEqual(model.homebrew?.snapshot?.packages.map(\.identity), prior.packages.map(\.identity))
        XCTAssertFalse(model.homebrewRefreshFailed)
        XCTAssertEqual(model.homebrewRefreshedAt, readTime)
        try FileManager.default.removeItem(at: fixture.directoryURL.appending(path: "fail-packages"))
        try await readHomebrew(fixture, into: model)
        model.homebrewPlan = try await fixture.client.planUpdate()
        await model.executeHomebrewPlan()
        XCTAssertFalse(model.homebrewRefreshFailed)
        XCTAssertNotEqual(model.homebrewRefreshedAt, readTime)
        XCTAssertEqual(model.homebrewUpdateState, .available)
        XCTAssertNotNil(model.homebrewOutdatedCheckedAt)
        XCTAssertFalse(model.isBusy)
    }

    func testNodeSwitchPostreadFailureBlocksOldEnvironmentAndSuccessfulRetryRecovers() async throws {
        let fixture = try NodeRefreshFixture()
        defer { fixture.remove() }
        let model = makeModel(root: fixture.root, managers: fixture.managers, batchProvider: FakeBatchProvider())
        let initial = try await model.service.loadNode(snapshot: fixture.managers)
        model.applyNodeReadResult(.success(initial))
        let readTime = model.nodeRefreshedAt
        let oldEnvironment = LibraryCatalog.context(initial.summary)
        let pending = try XCTUnwrap(BatchIntent(operation: .uninstall, items: [.npm(.init(name: "example", environment: oldEnvironment))]))
        // Prepare while healthy, then verify execution refuses the retained environment after failure.
        let oldPlan = try await model.prepareBatch(pending)
        try Data().write(to: fixture.root.appending(path: "fail-after-execute"))
        await model.performDirectNodeAction(.init(action: .useNode, subject: "v22.0.0"))
        XCTAssertEqual(model.preferredNodeVersion, "v22.0.0")
        XCTAssertEqual(model.node?.summary.nodeVersion, "v20.0.0")
        XCTAssertTrue(model.nodeRefreshFailed)
        XCTAssertEqual(model.nodeRefreshedAt, readTime)
        XCTAssertEqual(model.nodeUpdateState, .failed)
        XCTAssertNotNil(model.nodeOperationError)
        XCTAssertNil(model.discoverContext.npm)
        XCTAssertFalse(model.discoverContext.nodeAvailable)
        do {
            _ = try await model.prepareBatch(pending)
            XCTFail("A retained Node environment cannot prepare writes")
        } catch BatchOperationError.reconciliationUnavailable {}
        do {
            _ = try await model.executeBatch(oldPlan)
            XCTFail("A previously prepared plan cannot execute after a failed read")
        } catch BatchOperationError.reconciliationUnavailable {}
        try FileManager.default.removeItem(at: fixture.root.appending(path: "fail-after-execute"))
        await model.performDirectNodeAction(.init(action: .useNode, subject: "v22.0.0"))
        XCTAssertFalse(model.nodeRefreshFailed)
        XCTAssertEqual(model.node?.summary.nodeVersion, "v22.0.0")
        XCTAssertNotEqual(model.nodeRefreshedAt, readTime)
        XCTAssertEqual(model.nodeUpdateState, .available)
        XCTAssertNotNil(model.nodeOutdatedCheckedAt)
        XCTAssertNotNil(model.discoverContext.npm)
        XCTAssertFalse(model.isBusy)
    }

    func testNodeOperationAndRecoveryReadFailureRetainFailureThenRecoverWithOutdatedPartialFailure() async throws {
        let fixture = try NodeRefreshFixture()
        defer { fixture.remove() }
        let model = makeModel(root: fixture.root, managers: fixture.managers)
        let initial = try await model.service.loadNode(snapshot: fixture.managers)
        model.applyNodeReadResult(.success(initial))
        let readTime = model.nodeRefreshedAt
        try Data().write(to: fixture.root.appending(path: "execute-fails"))
        try Data().write(to: fixture.root.appending(path: "fail-after-execute"))
        await model.performDirectNodeAction(.init(action: .useNode, subject: "v22.0.0"))
        XCTAssertTrue(model.nodeRefreshFailed)
        XCTAssertEqual(model.nodeRefreshedAt, readTime)
        XCTAssertEqual(model.preferredNodeVersion, nil)
        for flag in ["execute-fails", "fail-after-execute"] { try FileManager.default.removeItem(at: fixture.root.appending(path: flag)) }
        try Data().write(to: fixture.root.appending(path: "outdated-fails"))
        await model.performDirectNodeAction(.init(action: .useNode, subject: "v22.0.0"))
        XCTAssertFalse(model.nodeRefreshFailed)
        XCTAssertEqual(model.node?.summary.nodeVersion, "v22.0.0")
        XCTAssertEqual(model.node?.packages.map(\.name), ["example"])
        XCTAssertNotNil(model.node?.outdatedError)
        XCTAssertEqual(model.nodeUpdateState, .failed)
        XCTAssertNotNil(model.nodeOutdatedCheckedAt)
        XCTAssertNotNil(model.discoverContext.npm)
    }

    func testIndependentHomebrewSectionFailuresDoNotDisableUnrelatedPackageActions() async throws {
        for section in [HomebrewSnapshot.Section.configuration, .packages, .taps, .outdated] {
            let fixture = try FakeBrewFixture()
            defer { fixture.remove() }
            let model = makeModel(root: fixture.directoryURL, homebrew: fixture.client)
            try await readHomebrew(fixture, into: model, includingOutdated: true)
            let prior = try XCTUnwrap(model.homebrew?.snapshot)
            let flag = section == .outdated ? "outdated-fails" : "fail-\(section.rawValue)"
            try Data().write(to: fixture.directoryURL.appending(path: flag))
            let freshSectionFlag = section == .packages ? "tap-added" : "new-installed"
            try Data().write(to: fixture.directoryURL.appending(path: freshSectionFlag))
            try await readHomebrew(fixture, into: model, includingOutdated: true)
            let partial = try XCTUnwrap(model.homebrew?.snapshot)
            XCTAssertEqual(Set(partial.sectionErrors.keys), [section])
            XCTAssertFalse(model.homebrewRefreshFailed)
            XCTAssertEqual(model.canMutatePackages(in: .homebrew(.formula)), section != .packages)
            XCTAssertEqual(model.discoverContext.homebrewAvailable, section != .packages)
            if section == .packages {
                XCTAssertEqual(partial.packages.map(\.identity), prior.packages.map(\.identity))
                XCTAssertEqual(partial.taps.count, prior.taps.count + 1)
            } else {
                XCTAssertEqual(partial.packages.count, prior.packages.count + 1)
            }
            if section == .outdated {
                XCTAssertEqual(partial.outdatedPackages.map(\.identity), prior.outdatedPackages.map(\.identity))
                XCTAssertEqual(model.homebrewUpdateState, .failed)
                XCTAssertTrue(model.updateCards.allSatisfy { $0.primaryAction != .update })
            } else {
                XCTAssertEqual(model.homebrewUpdateState, .available)
            }
        }
    }

    func testInitiallyUnknownHomebrewPrefixDoesNotDiscardSuccessfulSectionsWhenConfigurationRecovers() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        let model = makeModel(root: fixture.directoryURL, homebrew: fixture.client)
        try Data().write(to: fixture.directoryURL.appending(path: "fail-configuration"))
        try await readHomebrew(fixture, into: model, includingOutdated: true)
        let initial = try XCTUnwrap(model.homebrew?.snapshot)
        XCTAssertTrue(initial.configuration.prefix.isEmpty)
        XCTAssertFalse(initial.packages.isEmpty)
        XCTAssertFalse(initial.taps.isEmpty)
        XCTAssertNotNil(initial.sectionErrors[.configuration])
        XCTAssertNil(model.homebrewRefreshedAt)
        try FileManager.default.removeItem(at: fixture.directoryURL.appending(path: "fail-configuration"))
        for flag in ["fail-packages", "fail-taps", "outdated-fails"] {
            try Data().write(to: fixture.directoryURL.appending(path: flag))
        }
        try await readHomebrew(fixture, into: model, includingOutdated: true)
        let partial = try XCTUnwrap(model.homebrew?.snapshot)
        XCTAssertEqual(partial.configuration.prefix, "/opt/homebrew")
        XCTAssertEqual(partial.packages.map(\.identity), initial.packages.map(\.identity))
        XCTAssertEqual(partial.taps.map(\.name), initial.taps.map(\.name))
        XCTAssertEqual(partial.outdatedPackages.map(\.identity), initial.outdatedPackages.map(\.identity))
        XCTAssertEqual(Set(partial.sectionErrors.keys), [.packages, .taps, .outdated])
        XCTAssertFalse(model.homebrewRefreshFailed)
        XCTAssertNil(model.homebrewRefreshedAt)
        XCTAssertFalse(model.canMutatePackages(in: .homebrew(.formula)))
        XCTAssertFalse(model.discoverContext.homebrewAvailable)
    }

    func testHomebrewFailedSectionsAreNotMergedAcrossExecutableOrPrefixChanges() async throws {
        let first = try FakeBrewFixture()
        defer { first.remove() }
        let second = try FakeBrewFixture()
        defer { second.remove() }
        let model = makeModel(root: first.directoryURL)
        try await readHomebrew(first, into: model)
        try Data().write(to: second.directoryURL.appending(path: "fail-packages"))
        try await readHomebrew(second, into: model)
        XCTAssertEqual(model.homebrew?.snapshot?.packages.count, 0)
        try await readHomebrew(first, into: model)
        let known = try XCTUnwrap(model.homebrew?.snapshot)
        let changed = HomebrewSnapshot(executablePath: known.executablePath, version: known.version,
                                      configuration: .init(prefix: "/different", repository: "", cache: "", cellar: "", values: [:]),
                                      packages: [], outdatedPackages: [], taps: [], sectionErrors: [.packages: "unavailable"],
                                      controlledPath: known.controlledPath, commandLineToolsAvailable: true)
        model.applyHomebrewReadResult(.success(.init(executablePath: changed.executablePath, version: changed.version,
                                                   managerAvailable: true, snapshot: changed)))
        XCTAssertEqual(model.homebrew?.snapshot?.packages.count, 0)
    }

    func testHomebrewDirectTotalPostreadFailurePreservesSnapshotUntilRecovery() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        let model = makeModel(root: fixture.directoryURL, homebrew: fixture.client)
        try await readHomebrew(fixture, into: model)
        let prior = try XCTUnwrap(model.homebrew?.snapshot)
        let time = model.homebrewRefreshedAt
        model.homebrewPlan = try await fixture.client.planFormulaUninstall("acme/tools/demo")
        try Data().write(to: fixture.directoryURL.appending(path: "postflight-fails"))
        await model.executeHomebrewPlan()
        XCTAssertTrue(model.homebrewRefreshFailed)
        XCTAssertEqual(model.homebrewRefreshedAt, time)
        XCTAssertEqual(model.homebrew?.snapshot?.packages.map(\.identity), prior.packages.map(\.identity))
        XCTAssertEqual(model.homebrewUpdateState, .failed)
        XCTAssertFalse(model.canMutatePackages(in: .homebrew(.formula)))
        try FileManager.default.removeItem(at: fixture.directoryURL.appending(path: "postflight-fails"))
        try await readHomebrew(fixture, into: model)
        XCTAssertFalse(model.homebrewRefreshFailed)
        XCTAssertEqual(model.homebrew?.snapshot?.packages.count, prior.packages.count - 1)
        XCTAssertTrue(model.canMutatePackages(in: .homebrew(.formula)))
    }

    func testNodeFailedInitialReadRetainsNoEnvironmentAndDirectSelectionRecovers() async throws {
        let fixture = try NodeRefreshFixture()
        defer { fixture.remove() }
        let model = makeModel(root: fixture.root, managers: fixture.managers)
        try Data().write(to: fixture.root.appending(path: "executed"))
        try Data().write(to: fixture.root.appending(path: "fail-after-execute"))
        do {
            let snapshot = try await model.service.loadNode(snapshot: fixture.managers)
            model.applyNodeReadResult(.success(snapshot))
            XCTFail("The fixture must reject its initial summary")
        } catch {
            model.applyNodeReadResult(.failure(error))
        }
        XCTAssertNil(model.node)
        XCTAssertTrue(model.nodeRefreshFailed)
        XCTAssertNil(model.nodeRefreshedAt)
        XCTAssertNil(model.discoverContext.npm)
        try FileManager.default.removeItem(at: fixture.root.appending(path: "fail-after-execute"))
        await model.performDirectNodeAction(.init(action: .useNode, subject: "v22.0.0"))
        XCTAssertFalse(model.nodeRefreshFailed)
        XCTAssertEqual(model.node?.summary.nodeVersion, "v22.0.0")
        XCTAssertNotNil(model.nodeRefreshedAt)
        XCTAssertEqual(model.nodeUpdateState, .available)
    }

    private func readHomebrew(_ fixture: FakeBrewFixture, into model: AppModel, includingOutdated: Bool = false) async throws {
        let snapshot = try await fixture.client.loadSnapshot(includingOutdated: includingOutdated)
        model.applyHomebrewReadResult(.success(.init(executablePath: snapshot.executablePath, version: snapshot.version, managerAvailable: true, snapshot: snapshot)), includingOutdated: includingOutdated)
    }

    private func makeModel(root: URL, homebrew: HomebrewClient? = nil, managers: SnapshotStatus? = nil, batchProvider: (any BatchOperationProviding)? = nil, activityStore: ActivityStore? = nil) -> AppModel {
        let runner = ProcessRunner()
        let resolver = NodeEnvironmentResolver(homeDirectory: root)
        let service = SystemProbeService(runner: runner, installer: ManagerSnapshotInstaller(applicationSupportDirectory: root),
                                         nodeClient: NodeManagerClient(runner: runner, environmentResolver: resolver),
                                         shellClient: ShellManagerClient(runner: runner), environmentResolver: resolver, homebrewClient: homebrew)
        return AppModel(service: service, operationStore: OperationStore(), activityStore: activityStore, batchProvider: batchProvider, managerSnapshot: managers)
    }
}

private struct NodeRefreshFixture {
    let root: URL
    let managers: SnapshotStatus

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "CellarNodeRefresh-\(UUID())")
        let manager = root.appending(path: "node-manager")
        try FileManager.default.createDirectory(at: manager, withIntermediateDirectories: true)
        let alias = root.appending(path: ".nvm/alias")
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
        try Data("v20.0.0".utf8).write(to: alias.appending(path: "default"))
        for version in ["v20.0.0", "v22.0.0"] {
            let bin = root.appending(path: ".nvm/versions/node/\(version)/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            for name in ["node", "npm"] {
                let executable = bin.appending(path: name)
                try Data("#!/bin/sh\nexit 93\n".utf8).write(to: executable)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            }
        }
        let script = #"""
        #!/bin/bash
        set -eu
        printf '%s\n' "$2" >> "$HOME/calls"
        if [ "$2" = execute ]; then
          touch "$HOME/executed"
          if [ "$3" = cleanup ]; then
            printf '%s\n' '{"ok":false,"schemaVersion":1,"command":"execute","error":{"code":"cleanup-incomplete","operationId":"fixture-cleanup","action":"cleanup","subject":"orphan-bins","exitCode":1,"status":"partial","logFile":"","cleanupItems":[{"path":"/fixture/removed","status":"removed","reason":"removed"},{"path":"/fixture/failed","status":"failed","reason":"deletion-failed"},{"path":"/fixture/unattempted","status":"notAttempted","reason":"previous-failure"}]}}'
            exit 1
          fi
          if [ -f "$HOME/execute-fails" ]; then
            printf '%s\n' '{"ok":false,"schemaVersion":1,"command":"execute","error":{"code":"fixture-execute-failed"}}'
            exit 1
          fi
          printf '{"ok":true,"schemaVersion":1,"command":"execute","data":{"operationId":"fixture","action":"%s","subject":"%s","exitCode":0,"status":"ok","logFile":""}}\n' "$3" "$4"
          exit 0
        fi
        case "$2" in
          plan) printf '{"ok":true,"schemaVersion":1,"command":"plan","data":{"action":"%s","executeSupported":true,"executable":true,"normalizedVersion":"%s"}}\n' "$3" "$4" ;;
          summary)
            if [ -f "$HOME/executed" ] && [ -f "$HOME/fail-after-execute" ]; then exit 1; fi
            bin="${PATH%%:*}"
            version="$(basename "$(dirname "$bin")")"
            printf '{"ok":true,"schemaVersion":1,"command":"summary","data":{"nodePath":"%s/node","npmPath":"%s/npm","nodeVersion":"%s","npmVersion":"10.0.0","nvmLoaded":true,"globalPrefix":"%s","globalRoot":"%s/lib","registry":"https://fixture.invalid/"}}\n' "$bin" "$bin" "$version" "$bin" "$bin" ;;
          packages) printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"packages","data":{"dependencies":{"example":{"version":"1.0.0"}}}}' ;;
          config) printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"config","data":{"registry":"https://fixture.invalid/","cache":"/fixture/cache","prefix":"/fixture","userRegistry":"","projectRegistry":"","globalRegistry":""}}' ;;
          status) printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"status","data":{"ok":true,"runtimeDir":"/fixture","logDir":"/fixture/logs","tmpDir":"/fixture/tmp","jsonExecuteEnabled":true}}' ;;
          logs) printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"logs","data":[]}' ;;
          outdated)
            if [ -f "$HOME/outdated-fails" ]; then exit 1; fi
            printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"outdated","data":{}}' ;;
          *) exit 92 ;;
        esac
        """#
        try Data(script.utf8).write(to: manager.appending(path: "main.sh"))
        managers = SnapshotStatus(version: "fixture", location: root.path, nodeAvailable: true, homebrewAvailable: true, shellAvailable: false)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
