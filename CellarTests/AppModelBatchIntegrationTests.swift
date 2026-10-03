import XCTest
@testable import Cellar

@MainActor
final class AppModelBatchIntegrationTests: XCTestCase {
    func testNPMBatchReconciliationPinsFutureExecutionToDisplayedNode() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarAppBatchTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appending(path: ".nvm/alias")
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
        try Data("v20.0.0".utf8).write(to: alias.appending(path: "default"))
        for version in ["v20.0.0", "v22.0.0"] {
            let bin = root.appending(path: ".nvm/versions/node/\(version)/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let entry = bin.appending(path: "node")
            try Data("fixture only".utf8).write(to: entry)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entry.path)
        }
        let resolver = NodeEnvironmentResolver(homeDirectory: root)
        let runner = ProcessRunner()
        let service = SystemProbeService(runner: runner,
                                         installer: ManagerSnapshotInstaller(applicationSupportDirectory: root),
                                         nodeClient: NodeManagerClient(runner: runner, environmentResolver: resolver),
                                         shellClient: ShellManagerClient(runner: runner), environmentResolver: resolver)
        let provider = FakeBatchProvider()
        let model = AppModel(service: service, operationStore: OperationStore(), batchProvider: provider)
        let defaultEnvironment = NodeEnvironmentContext(identifier: "nvm:v20.0.0", nodeVersion: "v20.0.0", npmVersion: "10.0.0")
        model.node = try await provider.refreshNPM(defaultEnvironment)
        XCTAssertNil(model.preferredNodeVersion)
        let targetEnvironment = NodeEnvironmentContext(identifier: "nvm:v22.0.0", nodeVersion: "v22.0.0", npmVersion: "10.0.0")
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
