import XCTest
@testable import Cellar

@MainActor
final class AppModelBatchIntegrationTests: XCTestCase {
    func testSystemNodeBatchReconciliationDoesNotSelectSameVersionNVMInstallation() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarSystemNodeBatch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let nvmDirectory = root.appending(path: ".nvm/versions/node/v22.0.0")
        let systemDirectory = root.appending(path: "homebrew")
        for directory in [nvmDirectory, systemDirectory] {
            let bin = directory.appending(path: "bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            for name in ["node", "npm"] {
                let entry = bin.appending(path: name)
                try Data("fixture only".utf8).write(to: entry)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entry.path)
            }
        }
        let runner = ProcessRunner()
        let resolver = NodeEnvironmentResolver(homeDirectory: root)
        let service = SystemProbeService(runner: runner, installer: ManagerSnapshotInstaller(applicationSupportDirectory: root),
                                         nodeClient: NodeManagerClient(runner: runner, environmentResolver: resolver),
                                         shellClient: ShellManagerClient(runner: runner), environmentResolver: resolver)
        let model = AppModel(service: service, operationStore: OperationStore())
        let environment = NodeEnvironmentContext(identifier: systemDirectory.appending(path: "bin/node").path, nodeVersion: "v22.0.0", npmVersion: "10.0.0")
        let snapshot = NodeSnapshot(summary: .init(nodePath: environment.identifier, npmPath: systemDirectory.appending(path: "bin/npm").path,
                                                  nodeVersion: environment.nodeVersion, npmVersion: environment.npmVersion, nvmLoaded: false,
                                                  globalPrefix: systemDirectory.path, globalRoot: systemDirectory.appending(path: "lib/node_modules").path,
                                                  registry: "https://registry.npmjs.org"),
                                    configuration: .init(registry: "", cache: "", prefix: "", userRegistry: "", projectRegistry: "", globalRegistry: ""),
                                    packages: [], installations: [.init(version: environment.nodeVersion, directory: nvmDirectory.path, isActive: false, isDefault: true)],
                                    managerStatus: nil, logs: [], outdatedError: nil, maintenanceError: nil, packageEnvironment: environment)
        let item = BatchItem.npm(.init(name: "example", environment: environment))
        let intent = try XCTUnwrap(BatchIntent(operation: .install, items: [item]))
        let outcome = try XCTUnwrap(BatchOutcome(intent: intent, itemOutcomes: [.init(item: item, status: .succeeded, userFacingMessage: nil)]))
        for state in [BatchRefreshedState.npm(snapshot), .nodeRuntime(snapshot)] {
            model.applyBatchResult(.init(outcome: outcome, providerResults: [], refreshStatus: .succeeded, refreshedState: state))
            XCTAssertNil(model.preferredNodeVersion)
            XCTAssertEqual(model.nodePackageEnvironment, environment)
        }
    }

    func testHomebrewUnavailablePackagesReconciliationKeepsPriorInventoryAndTime() async throws {
        try await assertHomebrewPartialReconciliation(throughUpdateBatch: false)
    }

    func testHomebrewUpdateBatchPublishesPartialReconciliationAndRecovers() async throws {
        try await assertHomebrewPartialReconciliation(throughUpdateBatch: true)
    }

    private func assertHomebrewPartialReconciliation(throughUpdateBatch: Bool) async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        let runner = ProcessRunner()
        let root = fixture.directoryURL
        let service = SystemProbeService(runner: runner, installer: ManagerSnapshotInstaller(applicationSupportDirectory: root),
                                         nodeClient: NodeManagerClient(runner: runner, environmentResolver: .init(homeDirectory: root)),
                                         shellClient: ShellManagerClient(runner: runner), environmentResolver: .init(homeDirectory: root),
                                         homebrewClient: fixture.client)
        let initial = try await fixture.client.loadSnapshot()
        let refreshedTap = HomebrewTap(name: "fresh/tools", remote: nil, path: root.appending(path: "fresh-tap").path,
                                       official: false, trusted: false, formulaNames: [], caskTokens: [])
        let refreshedConfiguration = HomebrewConfiguration(prefix: initial.configuration.prefix,
                                                            repository: initial.configuration.repository,
                                                            cache: root.appending(path: "fresh-cache").path,
                                                            cellar: initial.configuration.cellar, values: ["fixture": "fresh"])
        let partial = HomebrewSnapshot(executablePath: initial.executablePath, version: "Homebrew 5.1.0",
                                       configuration: refreshedConfiguration, packages: [], outdatedPackages: [], taps: [refreshedTap],
                                       sectionErrors: [.packages: "fixture unavailable"], controlledPath: initial.controlledPath,
                                       commandLineToolsAvailable: true)
        let provider = FakeBatchProvider(homebrewRefreshSnapshot: partial)
        let activity = ActivityStore()
        let model = AppModel(service: service, operationStore: OperationStore(), activityStore: activity, batchProvider: provider)
        model.applyHomebrewReadResult(.success(.init(executablePath: initial.executablePath, version: initial.version,
                                                   managerAvailable: true, snapshot: initial)), includingOutdated: true)
        model.refreshedAt = Date(timeIntervalSince1970: 100)
        let providerDate = model.homebrewRefreshedAt
        let globalDate = model.refreshedAt
        let intent = try XCTUnwrap(BatchIntent(operation: throughUpdateBatch ? .update : .install,
                                               items: [.homebrew(.init(name: "one", kind: .formula))]))
        let result: BatchExecutionResult
        if throughUpdateBatch {
            let plan = try await model.prepareUpdateBatch([intent])
            let execution = try await model.executeUpdateBatch(plan)
            result = try XCTUnwrap(execution.groups.first)
        } else {
            let plan = try await model.prepareBatch(intent)
            result = try await model.executeBatch(plan)
        }
        XCTAssertEqual(result.refreshStatus, .failed)
        XCTAssertEqual(result.outcome.itemOutcomes.map(\.status), [.succeeded])
        XCTAssertNotNil(result.refreshedState)
        XCTAssertTrue(activity.summaries.contains { $0.operation == .refresh && $0.status == .failed && $0.reason == .stateUnavailable })
        let displayed = try XCTUnwrap(model.homebrew?.snapshot)
        XCTAssertEqual(displayed.packages.map(\.identity), initial.packages.map(\.identity))
        XCTAssertEqual(displayed.configuration.cache, refreshedConfiguration.cache)
        XCTAssertEqual(displayed.configuration.values, ["fixture": "fresh"])
        XCTAssertEqual(displayed.taps.map(\.name), [refreshedTap.name])
        XCTAssertEqual(Set(displayed.sectionErrors.keys), [.packages])
        XCTAssertEqual(model.homebrew?.version, "Homebrew 5.1.0")
        XCTAssertEqual(model.homebrewRefreshedAt, providerDate)
        XCTAssertNotEqual(model.refreshedAt, globalDate)
        XCTAssertFalse(model.homebrewRefreshFailed)
        XCTAssertFalse(model.canMutatePackages(in: intent.scope))
        do {
            _ = try await model.prepareBatch(intent)
            XCTFail("Partial reconciliation cannot authorize another package mutation")
        } catch BatchOperationError.reconciliationUnavailable {}
        // A fresh Tap read remains usable while the independent package inventory is stale.
        await model.prepareHomebrewAddTap("newco/apps")
        XCTAssertNotNil(model.homebrewPlan)
        await model.executeHomebrewPlan()
        XCTAssertEqual(model.homebrewActionResult?.outcome, .succeeded)
        XCTAssertNil(model.homebrewOperationError)
        XCTAssertTrue(try XCTUnwrap(model.homebrew?.snapshot).sectionErrors.isEmpty)
        XCTAssertTrue(model.homebrew?.snapshot?.taps.contains { $0.name == "newco/apps" } == true)
        XCTAssertFalse(model.homebrewRefreshFailed)
        XCTAssertNotEqual(model.homebrewRefreshedAt, providerDate)
        XCTAssertTrue(model.canMutatePackages(in: intent.scope))
        XCTAssertFalse(model.isBusy)
    }

    func testNPMBatchReconciliationPinsFutureExecutionToDisplayedNode() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarAppBatchTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appending(path: ".nvm/alias")
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
        try Data("v20.0.0".utf8).write(to: alias.appending(path: "default"))
        for version in ["v20.0.0", "v22.0.0"] {
            let bin = root.appending(path: ".nvm/versions/node/\(version)/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            for name in ["node", "npm"] {
                let entry = bin.appending(path: name)
                try Data("fixture only".utf8).write(to: entry)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entry.path)
            }
        }
        let resolver = NodeEnvironmentResolver(homeDirectory: root)
        let runner = ProcessRunner()
        let service = SystemProbeService(runner: runner,
                                         installer: ManagerSnapshotInstaller(applicationSupportDirectory: root),
                                         nodeClient: NodeManagerClient(runner: runner, environmentResolver: resolver),
                                         shellClient: ShellManagerClient(runner: runner), environmentResolver: resolver)
        let provider = FakeBatchProvider()
        let model = AppModel(service: service, operationStore: OperationStore(), batchProvider: provider)
        let defaultEnvironment = NodeEnvironmentContext(identifier: root.appending(path: ".nvm/versions/node/v20.0.0/bin/node").path, nodeVersion: "v20.0.0", npmVersion: "10.0.0")
        model.node = try await provider.refreshNPM(defaultEnvironment)
        XCTAssertNil(model.preferredNodeVersion)
        let targetEnvironment = NodeEnvironmentContext(identifier: root.appending(path: ".nvm/versions/node/v22.0.0/bin/node").path, nodeVersion: "v22.0.0", npmVersion: "10.0.0")
        let alternate = try XCTUnwrap(BatchIntent(operation: .install, items: [.npm(.init(name: "example", environment: targetEnvironment))]))
        do { _ = try await model.prepareBatch(alternate); XCTFail("The displayed v20 context cannot authorize v22") }
        catch BatchOperationError.reconciliationUnavailable {}
        // The displayed target is a controlled read; reconciliation must also pin future resolver calls to it.
        model.node = try await provider.refreshNPM(targetEnvironment)
        XCTAssertNil(model.preferredNodeVersion)
        let intent = try XCTUnwrap(BatchIntent(operation: .install, items: [.npm(.init(name: "example", environment: targetEnvironment))]))
        let plan = try await model.prepareBatch(intent)
        _ = try await model.executeBatch(plan)

        XCTAssertEqual(model.node?.summary.nodeVersion, "v22.0.0")
        XCTAssertEqual(model.preferredNodeVersion, "v22.0.0")
        let nextEnvironment = resolver.environment(preferredNodeVersion: model.preferredNodeVersion)
        let path = try XCTUnwrap(nextEnvironment["PATH"]?.split(separator: ":").first)
        XCTAssertEqual(URL(filePath: String(path)).resolvingSymlinksInPath().path,
                       root.appending(path: ".nvm/versions/node/v22.0.0/bin").resolvingSymlinksInPath().path)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.operationStore.hasActiveOperations)
    }
}
