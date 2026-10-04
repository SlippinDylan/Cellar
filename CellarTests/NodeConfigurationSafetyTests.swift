import XCTest
@testable import Cellar

final class NodeConfigurationSafetyTests: XCTestCase {
    func testRegistryReferencedConfigurationAndSameContentReplacementInvalidatePlans() async throws {
        let fixture = try NodeConfigurationFixture()
        defer { fixture.remove() }
        let referenced = fixture.root.appending(path: "registry-config")
        try Data("registry=https://registry.example.test/\n".utf8).write(to: referenced)
        try Data("globalconfig=\(referenced.path)\n".utf8).write(to: fixture.root.appending(path: ".npmrc"))
        let request = NodeActionRequest(action: .setRegistry, subject: "https://registry.example.test/")
        let plan = try await fixture.client.plan(request, managerDirectory: fixture.root)
        let bytes = try Data(contentsOf: referenced)
        try FileManager.default.removeItem(at: referenced)
        try bytes.write(to: referenced)
        do { _ = try await fixture.client.execute(plan, managerDirectory: fixture.root); XCTFail("Replacement must invalidate even when contents match") }
        catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "registry-state-changed") }
        XCTAssertFalse(try fixture.calls().contains("execute"))
        try Data(repeating: 32, count: 65_537).write(to: referenced)
        do { _ = try await fixture.client.plan(request, managerDirectory: fixture.root); XCTFail("Referenced config must be bounded") }
        catch { }
    }

    func testProjectAndRegistryFingerprintRejectOversizedInputsBeforeManagerReads() async throws {
        for name in ["package.json", ".nvmrc", ".npmrc"] {
            let fixture = try NodeConfigurationFixture()
            defer { fixture.remove() }
            try Data(repeating: 32, count: 2 * 1_024 * 1_024 + 1).write(to: fixture.root.appending(path: name))
            let request: NodeActionRequest = name == ".npmrc" ? .init(action: .setRegistry, subject: "https://registry.example.test/")
                : .init(action: .writeProjectNVMRC, subject: fixture.root.path, value: "v24.0.0")
            do { _ = try await fixture.client.plan(request, managerDirectory: fixture.root); XCTFail("Oversized fingerprint input must refuse") }
            catch { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appending(path: "calls.log").path))
        }
    }

    func testLogMaintenanceListsExactCandidatesAndRefusesChangedInventory() async throws {
        let fixture = try NodeConfigurationFixture()
        defer { fixture.remove() }
        let logs = fixture.root.appending(path: ".runtime/logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        for index in 0..<105 {
            let log = logs.appending(path: "fixture.log.\(index)")
            try Data("log".utf8).write(to: log)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10_000 - Double(index))], ofItemAtPath: log.path)
        }
        let plan = try await fixture.client.plan(NodeMaintenanceAction.logs.request, managerDirectory: fixture.root)
        XCTAssertEqual(plan.maintenanceCandidates.count, 6)
        XCTAssertEqual(plan.maintenanceCandidates.map { URL(filePath: $0).lastPathComponent }, (99..<105).map { "fixture.log.\($0)" })
        try Data("new log".utf8).write(to: logs.appending(path: "fixture.log.new"))
        do { _ = try await fixture.client.execute(plan, managerDirectory: fixture.root); XCTFail("Changed log inventory must reject confirmation") }
        catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "plan-stale") }
        XCTAssertFalse(try fixture.calls().contains("execute"))
    }

    func testRegistryChangesRequireFreshSingleConfirmationAndGate() async throws {
        let fixture = try NodeConfigurationFixture()
        defer { fixture.remove() }
        try Data("registry=http://registry.example.test/\n".utf8).write(to: fixture.root.appending(path: ".npmrc"))
        let request = NodeActionRequest(action: .setRegistry, subject: "https://registry.example.test/")
        let plan = try await fixture.client.plan(request, managerDirectory: fixture.root)
        XCTAssertFalse(try fixture.calls().contains("execute|1"))
        try Data("registry=http://changed.example.test/\n".utf8).write(to: fixture.root.appending(path: ".npmrc"))
        do { _ = try await fixture.client.execute(plan, managerDirectory: fixture.root); XCTFail("Changed config must reject confirmation") }
        catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "registry-state-changed") }
        XCTAssertFalse(try fixture.calls().contains("execute|1"))
        let fresh = try await fixture.client.plan(request, managerDirectory: fixture.root)
        let result = try await fixture.client.execute(fresh, managerDirectory: fixture.root)
        XCTAssertEqual(result.status, "ok")
        XCTAssertTrue(try fixture.calls().contains("execute|1|0|registry-set"))
        do { _ = try await fixture.client.execute(fresh, managerDirectory: fixture.root); XCTFail("Confirmation must be consumed once") }
        catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "registry-state-changed") }
    }

    func testRegistryScopeValidationPreventsQueriesAndWrites() async throws {
        let fixture = try NodeConfigurationFixture()
        defer { fixture.remove() }
        for request in [NodeActionRequest(action: .setScopeRegistry, subject: "@Bad", value: "https://example.test/"),
                        .init(action: .setRegistry, subject: "https://user:secret@example.test/"),
                        .init(action: .deleteScopeRegistry, subject: "@scope/name")] {
            do { _ = try await fixture.client.plan(request, managerDirectory: fixture.root); XCTFail("Invalid boundary input must fail") }
            catch { XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appending(path: "calls.log").path)) }
        }
        for request in [NodeActionRequest(action: .setScopeRegistry, subject: "@company", value: "http://registry.example.test/"),
                        .init(action: .deleteScopeRegistry, subject: "@company"), .init(action: .deleteRegistry)] {
            let plan = try await fixture.client.plan(request, managerDirectory: fixture.root)
            _ = try await fixture.client.execute(plan, managerDirectory: fixture.root)
        }
        XCTAssertEqual(try fixture.calls().split(separator: "\n").filter { $0.hasPrefix("execute|1|0") }.count, 3)
    }

    func testProjectWriteRejectsDriftThenUsesOnlyProjectGate() async throws {
        let fixture = try NodeConfigurationFixture()
        defer { fixture.remove() }
        let project = fixture.root.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appending(path: ".nvmrc")
        try Data("v22.0.0\n".utf8).write(to: file)
        let request = NodeActionRequest(action: .writeProjectNVMRC, subject: project.path, value: "v24.0.0")
        let plan = try await fixture.client.plan(request, managerDirectory: fixture.root)
        try Data("v23.0.0\n".utf8).write(to: file)
        do { _ = try await fixture.client.execute(plan, managerDirectory: fixture.root); XCTFail("Changed project contents must reject old confirmation") }
        catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "plan-stale") }
        XCTAssertFalse(try fixture.calls().contains("execute"))
        let fresh = try await fixture.client.plan(request, managerDirectory: fixture.root)
        _ = try await fixture.client.execute(fresh, managerDirectory: fixture.root)
        XCTAssertTrue(try fixture.calls().contains("execute|1|1|project-nvmrc"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "v24.0.0\n")
    }

    func testProjectReadOnlyUsesSelectedDirectoryAndRefusesSymlink() async throws {
        let fixture = try NodeConfigurationFixture()
        defer { fixture.remove() }
        let project = fixture.root.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let service = ProjectConfigurationService()
        let missing = try await service.readNVMRC(in: project)
        XCTAssertNil(missing)
        let file = project.appending(path: ".nvmrc")
        try Data("v24.0.0\n".utf8).write(to: file)
        let current = try await service.readNVMRC(in: project)
        XCTAssertEqual(current, "v24.0.0")
        let target = fixture.root.appending(path: "outside")
        try FileManager.default.moveItem(at: file, to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        do { _ = try await service.readNVMRC(in: project); XCTFail("Symlink must not be read as project config") }
        catch { XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "v24.0.0\n") }
    }

    func testNVMDefaultChangeInvalidatesConfigurationConfirmation() async throws {
        let fixture = try NodeConfigurationFixture()
        defer { fixture.remove() }
        let alias = fixture.root.appending(path: ".nvm/alias/default")
        try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("v22.0.0\n".utf8).write(to: alias)
        let plan = try await fixture.client.plan(.init(action: .setDefaultNode, subject: "v24.0.0"), managerDirectory: fixture.root)
        try Data("v23.0.0\n".utf8).write(to: alias)
        do { _ = try await fixture.client.execute(plan, managerDirectory: fixture.root); XCTFail("Default drift must invalidate confirmation") }
        catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "plan-stale") }
        XCTAssertFalse(try fixture.calls().contains("execute"))
    }
}

private struct NodeConfigurationFixture {
    let root: URL
    let client: NodeManagerClient
    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "CellarNodeConfigurationTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = #"""
        #!/bin/bash
        printf '%s|%s|%s|%s\n' "$2" "$NODE_MANAGER_ALLOW_JSON_EXECUTE" "${NODE_MANAGER_ALLOW_PROJECT_WRITE:-0}" "$3" >> "$HOME/calls.log"
        case "$2" in
          plan)
            printf '{"ok":true,"schemaVersion":1,"command":"plan","data":{"action":"%s","effectiveRegistry":"http://registry.example.test/","userRegistry":"","projectRegistry":"","globalRegistry":"","executeSupported":true,"executable":true}}\n' "$3"
            ;;
          execute)
            if [ "$3" = project-nvmrc ]; then printf '%s\n' "$5" > "$4/.nvmrc"; fi
            printf '{"ok":true,"schemaVersion":1,"command":"execute","data":{"operationId":"fixture","action":"%s","subject":"%s","exitCode":0,"status":"ok","logFile":""}}\n' "$3" "$4"
            ;;
          *) exit 2 ;;
        esac
        """#
        try Data(script.utf8).write(to: root.appending(path: "main.sh"))
        client = NodeManagerClient(runner: ProcessRunner(), environmentResolver: NodeEnvironmentResolver(homeDirectory: root))
    }
    func calls() throws -> String { try String(contentsOf: root.appending(path: "calls.log"), encoding: .utf8) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
