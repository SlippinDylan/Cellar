import XCTest
@testable import Cellar

final class NodePackageEnvironmentTests: XCTestCase {
    func testPackageActionUsesExplicitInstallationAndOneInvocationWriteGate() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let identity = NPMPackageIdentity(name: "example", environment: fixture.context)
        let plan = try await fixture.client.planPackage(identity, action: .installPackage, managerDirectory: fixture.root)
        let result = try await fixture.client.executePackage(plan, environment: fixture.context, managerDirectory: fixture.root)

        XCTAssertEqual(result.status, "ok")
        let calls = try String(contentsOf: fixture.log, encoding: .utf8).split(separator: "\n").map(String.init)
        let selectedPath = fixture.selectedBin.resolvingSymlinksInPath().path
        XCTAssertEqual(calls.count, 4)
        let fields = calls.map { $0.components(separatedBy: "|") }
        XCTAssertEqual(fields.map { $0[0] }, ["summary", "plan", "summary", "execute"])
        XCTAssertEqual(fields.map { $0[1] }, ["0", "0", "0", "1"])
        for call in fields {
            let firstPath = try XCTUnwrap(call[2].split(separator: ":").first)
            XCTAssertEqual(URL(filePath: String(firstPath)).resolvingSymlinksInPath().path, selectedPath)
        }
        XCTAssertFalse(calls.contains { $0.contains("v20.0.0/bin:") })
    }

    func testRemovedInstallationIsRejectedBeforeExecuteOrFallbackRefresh() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let plan = try await fixture.client.planPackage(.init(name: "example", environment: fixture.context),
                                                        action: .uninstallPackage, managerDirectory: fixture.root)
        try FileManager.default.removeItem(at: fixture.selectedBin.appending(path: "node"))
        do {
            _ = try await fixture.client.executePackage(plan, environment: fixture.context, managerDirectory: fixture.root)
            XCTFail("Removed environment must never fall back to the default Node")
        } catch {
            guard case BridgeError.managerFailure(let code, _) = error else { return XCTFail("Expected environment failure") }
            XCTAssertEqual(code, "node-environment-changed")
        }
        do {
            _ = try await fixture.client.loadPackageSnapshot(fixture.context, managerDirectory: fixture.root)
            XCTFail("Refresh must retain its package environment")
        } catch {}
        let calls = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertFalse(calls.contains("execute|"))
        XCTAssertEqual(calls.split(separator: "\n").count, 2)
    }

    func testChangedNPMVersionRejectsWriteBeforeOpeningGate() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let plan = try await fixture.client.planPackage(.init(name: "example", environment: fixture.context),
                                                        action: .updatePackage, managerDirectory: fixture.root)
        try Data().write(to: fixture.root.appending(path: "npm-changed"))
        do {
            _ = try await fixture.client.executePackage(plan, environment: fixture.context, managerDirectory: fixture.root)
            XCTFail("Confirmed Node/npm context changed")
        } catch {
            guard case BridgeError.managerFailure(let code, _) = error else { return XCTFail("Expected environment failure") }
            XCTAssertEqual(code, "node-environment-changed")
        }
        let calls = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertFalse(calls.contains("execute|"))
        XCTAssertFalse(calls.contains("|1|"))
        XCTAssertEqual(calls.split(separator: "\n").count, 3)
    }
}

private struct PackageManagerFixture {
    let root: URL
    let selectedBin: URL
    let log: URL
    let client: NodeManagerClient
    let context = NodeEnvironmentContext(identifier: "nvm:v22.0.0", nodeVersion: "v22.0.0", npmVersion: "10.0.0")

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "CellarNodePackageTests-\(UUID().uuidString)")
        selectedBin = root.appending(path: ".nvm/versions/node/v22.0.0/bin")
        log = root.appending(path: "calls.log")
        for version in ["v20.0.0", "v22.0.0"] {
            let bin = root.appending(path: ".nvm/versions/node/\(version)/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let node = bin.appending(path: "node")
            try Data("fixture only".utf8).write(to: node)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
        }
        let alias = root.appending(path: ".nvm/alias")
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
        try Data("v20.0.0".utf8).write(to: alias.appending(path: "default"))
        let script = #"""
        #!/bin/bash
        printf '%s|%s|%s\n' "$2" "$NODE_MANAGER_ALLOW_JSON_EXECUTE" "$PATH" >> '\#(log.path)'
        if [ "$2" = summary ]; then
          npm_version=10.0.0
          [ ! -e '\#(root.path)/npm-changed' ] || npm_version=11.0.0
          printf '{"ok":true,"schemaVersion":1,"command":"summary","data":{"nodePath":"/fake/node","npmPath":"/fake/npm","nodeVersion":"v22.0.0","npmVersion":"%s","nvmLoaded":false,"globalPrefix":"/fake","globalRoot":"/fake","registry":"https://registry.npmjs.org"}}\n' "$npm_version"
        elif [ "$2" = plan ]; then
          printf '{"ok":true,"schemaVersion":1,"command":"plan","data":{"action":"%s","subject":"%s","packageName":"%s","executeSupported":true,"executable":true}}\n' "$3" "$4" "$4"
        elif [ "$2" = execute ]; then
          printf '{"ok":true,"schemaVersion":1,"command":"execute","data":{"operationId":"fake","action":"%s","subject":"%s","exitCode":0,"status":"ok","logFile":"/fake/log"}}\n' "$3" "$4"
        else
          exit 2
        fi
        """#
        try Data(script.utf8).write(to: root.appending(path: "main.sh"))
        client = NodeManagerClient(runner: ProcessRunner(), environmentResolver: NodeEnvironmentResolver(homeDirectory: root))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
