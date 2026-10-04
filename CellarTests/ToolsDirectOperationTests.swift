import XCTest
@testable import Cellar

@MainActor
final class ToolsDirectOperationTests: XCTestCase {
    func testFailedOrCancelledDirectPreparationCannotConsumePendingRegistryConfirmation() async throws {
        let requests = [NodeActionRequest(action: .installNode, subject: "v24.0.0"), .init(action: .useNode, subject: "v22.0.0"), NodeMaintenanceAction.verify.request]
        for cancelled in [false, true] {
            for request in requests {
                let fixture = try ToolsDirectFixture()
                defer { fixture.remove() }
                let pending = try await fixture.node.plan(.init(action: .setRegistry, subject: "https://registry.example.test/"), managerDirectory: fixture.root.appending(path: "node-manager"))
                fixture.model.nodePlan = pending
                try Data((cancelled ? "wait" : "fail").utf8).write(to: fixture.root.appending(path: "mode"))
                let action = Task { await fixture.model.performDirectNodeAction(request) }
                if cancelled {
                    try await fixture.waitForRead()
                    fixture.model.operationStore.cancelActiveTask()
                }
                await action.value
                XCTAssertEqual(fixture.model.nodePlan?.id, pending.id)
                XCTAssertFalse(try fixture.calls().contains("execute|1"))
            }
        }
    }

    func testFailedOrCancelledMetadataPreparationCannotConsumePendingTap() async throws {
        for cancelled in [false, true] {
            let fixture = try ToolsDirectFixture()
            defer { fixture.remove() }
            let pending = Self.tapPlan()
            fixture.model.homebrewPlan = pending
            if !cancelled { try FileManager.default.removeItem(at: fixture.root.appending(path: "brew")) }
            let action = Task { await fixture.model.performHomebrewMetadataUpdate() }
            if cancelled { action.cancel() }
            await action.value
            XCTAssertEqual(fixture.model.homebrewPlan?.id, pending.id)
            XCTAssertFalse(try fixture.calls().contains("tap|"))
        }
    }

    func testOldTapSheetDismissalCannotClearNewMetadataPlan() throws {
        let fixture = try ToolsDirectFixture()
        defer { fixture.remove() }
        let old = Self.tapPlan()
        fixture.model.homebrewPlan = old
        let binding = ProviderTaskPresentation(model: fixture.model, surface: .sources).homebrewConfirmation
        XCTAssertEqual(binding.wrappedValue?.id, old.id)
        let newer = Self.tapPlan(action: .update)
        fixture.model.homebrewPlan = newer
        binding.wrappedValue = nil
        XCTAssertEqual(fixture.model.homebrewPlan?.id, newer.id)
    }

    func testOldNodeAndShellDismissalCannotClearNewSameSurfacePlan() throws {
        let fixture = try ToolsDirectFixture()
        defer { fixture.remove() }
        let payload = try JSONDecoder().decode(NodeActionPlanPayload.self, from: Data(#"{"action":"registry-set","executeSupported":true,"executable":true}"#.utf8))
        let old = NodeActionPlan(id: UUID(), request: .init(action: .setRegistry, subject: "https://old.example.test"), payload: payload, generatedAt: Date())
        fixture.model.nodePlan = old
        let nodeBinding = ProviderTaskPresentation(model: fixture.model, surface: .sources).nodeConfirmation
        let newer = NodeActionPlan(id: UUID(), request: old.request, payload: payload, generatedAt: Date())
        fixture.model.nodePlan = newer
        nodeBinding.wrappedValue = nil
        XCTAssertEqual(fixture.model.nodePlan?.id, newer.id)
        let shellPayload = try JSONDecoder().decode(ShellActionPlanPayload.self, from: Data(#"{"action":"tidy","subject":"zsh-files","targetPath":"/fixture","requiresConfirmation":true,"executable":true,"blockedReason":"","planToken":"fixture","generatedAt":0}"#.utf8))
        let oldShell = ShellActionPlan(id: UUID(), request: .init(action: .tidy, subject: "zsh-files"), payload: shellPayload, generatedAt: Date())
        fixture.model.shellPlan = oldShell
        let shellBinding = ProviderTaskPresentation(model: fixture.model, surface: .tools).shellConfirmation
        let newerShell = ShellActionPlan(id: UUID(), request: oldShell.request, payload: shellPayload, generatedAt: Date())
        fixture.model.shellPlan = newerShell
        shellBinding.wrappedValue = nil
        XCTAssertEqual(fixture.model.shellPlan?.id, newerShell.id)
    }

    static func tapPlan(action: HomebrewAction = .addTap) -> HomebrewActionPlan {
        .init(id: UUID(), action: action, targets: [], tapName: "fixture/tap", dependencies: [], dependents: [], artifacts: [], residualPaths: [], associatedPackages: [], generatedAt: Date(), stateFingerprint: nil)
    }
}

@MainActor
private struct ToolsDirectFixture {
    let root: URL
    let node: NodeManagerClient
    let model: AppModel
    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "CellarDirectSafety-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = #"""
        #!/bin/bash
        printf '%s|%s|%s\n' "$2" "${NODE_MANAGER_ALLOW_JSON_EXECUTE:-0}" "$3" >> "$HOME/calls.log"
        if [ "$2" = plan ] && [ "$3" != registry-set ]; then
          /usr/bin/touch "$HOME/started"
          if [ "$(/bin/cat "$HOME/mode")" = wait ]; then /bin/sleep 30; fi
          printf '%s\n' '{"ok":false,"schemaVersion":1,"command":"plan","error":{"code":"fixture-failed"}}'
          exit 1
        fi
        case "$2" in
          plan) printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"plan","data":{"action":"registry-set","effectiveRegistry":"https://registry.example.test/","executeSupported":true,"executable":true}}' ;;
          execute) printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"execute","data":{"operationId":"fixture","action":"registry-set","subject":"registry","exitCode":0,"status":"ok","logFile":""}}' ;;
          *) exit 2 ;;
        esac
        """#
        try Data(script.utf8).write(to: root.appending(path: "main.sh"))
        let brew = root.appending(path: "brew")
        let brewScript = """
        #!/bin/bash
        printf '%s|brew\\n' "$1" >> '\(root.path)/calls.log'
        /usr/bin/touch '\(root.path)/started'
        if [ "$(/bin/cat '\(root.path)/mode')" = wait ]; then /bin/sleep 30; fi
        exit 1
        """
        try Data(brewScript.utf8).write(to: brew)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
        let runner = ProcessRunner()
        let resolver = NodeEnvironmentResolver(homeDirectory: root)
        node = NodeManagerClient(runner: runner, environmentResolver: resolver)
        let service = SystemProbeService(runner: runner, installer: ManagerSnapshotInstaller(applicationSupportDirectory: root), nodeClient: node,
                                         shellClient: ShellManagerClient(runner: runner, environmentResolver: .init(homeDirectory: root)), environmentResolver: resolver,
                                         homebrewClient: HomebrewClient(brewURL: brew, runner: runner))
        model = AppModel(service: service, operationStore: OperationStore(), managerSnapshot: .init(version: "fixture", location: root.path, nodeAvailable: true, homebrewAvailable: true, shellAvailable: true))
        // The fake main script is exactly the Node manager for this injected snapshot.
        try FileManager.default.createDirectory(at: root.appending(path: "node-manager"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appending(path: "main.sh"), to: root.appending(path: "node-manager/main.sh"))
    }
    func calls() throws -> String {
        let file = root.appending(path: "calls.log")
        if !FileManager.default.fileExists(atPath: file.path) { return "" }
        return try String(contentsOf: file, encoding: .utf8)
    }
    func waitForRead() async throws {
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: root.appending(path: "started").path), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "started").path))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
