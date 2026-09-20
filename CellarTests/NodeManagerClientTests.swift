import XCTest
@testable import Cellar

final class NodeManagerClientTests: XCTestCase {
    func testKeepsCoreNodeDataWhenOutdatedCheckFails() async throws {
        let manager = FileManager.default.temporaryDirectory
            .appending(path: "CellarNodeManagerClientTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: manager, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: manager) }

        let script = manager.appending(path: "main.sh")
        let contents = #"""
        #!/bin/bash
        case "$2" in
          summary)
            printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"summary","data":{"nodePath":"/test/node","npmPath":"/test/npm","nodeVersion":"v24.0.0","npmVersion":"11.0.0","nvmLoaded":false,"globalPrefix":"/test","globalRoot":"/test/lib/node_modules","registry":"https://registry.npmjs.org/"}}'
            ;;
          packages)
            printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"packages","data":{"dependencies":{"example":{"version":"1.0.0"}}}}'
            ;;
          config)
            printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"config","data":{"registry":"https://registry.npmjs.org/","cache":"/test/cache","prefix":"/test","userRegistry":"","projectRegistry":"","globalRegistry":""}}'
            ;;
          status)
            printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"status","data":{"ok":true,"runtimeDir":"/test/runtime","logDir":"/test/logs","tmpDir":"/test/tmp","jsonExecuteEnabled":false}}'
            ;;
          logs)
            printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"logs","data":["/test/logs/one.log"]}'
            ;;
          outdated)
            printf '%s\n' '{"ok":false,"schemaVersion":1,"command":"outdated","error":{"code":"npm-outdated-failed","stderr":"offline"}}'
            exit 1
            ;;
          *) exit 2 ;;
        esac
        """#
        try Data(contents.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let client = NodeManagerClient(runner: ProcessRunner())
        let snapshot = try await client.loadSnapshot(managerDirectory: manager)

        XCTAssertEqual(snapshot.summary.nodeVersion, "v24.0.0")
        XCTAssertEqual(snapshot.configuration.prefix, "/test")
        XCTAssertEqual(snapshot.packages.count, 1)
        XCTAssertEqual(snapshot.packages.first?.name, "example")
        XCTAssertEqual(snapshot.managerStatus?.logDir, "/test/logs")
        XCTAssertEqual(snapshot.logs, ["/test/logs/one.log"])
        XCTAssertNotNil(snapshot.outdatedError)
    }

    func testPlansAndExecutesConfirmedActionWithWriteGate() async throws {
        let manager = FileManager.default.temporaryDirectory
            .appending(path: "CellarNodeManagerClientTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: manager, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: manager) }

        let script = manager.appending(path: "main.sh")
        let log = manager.appending(path: "calls.log")
        let contents = #"""
        #!/bin/bash
        printf '%s|%s|%s|%s|%s|%s\n' "$2" "${3:-}" "${4:-}" "${5:-}" "${NODE_MANAGER_ALLOW_JSON_EXECUTE:-}" "${NODE_MANAGER_ALLOW_PROJECT_WRITE:-}" >> '\#(log.path)'
        if [ "$2" = plan ] && [ "$3" = project-nvmrc ]; then
          printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"plan","data":{"ok":true,"schemaVersion":1,"action":"project-nvmrc","targetType":"project-nvmrc","subject":"/test/project","value":"v22.14.0","requiresConfirmation":true,"executeSupported":true,"externalWrite":true,"pathExists":true,"pathIsDirectory":true,"nvmrcPath":"/test/project/.nvmrc","currentNvmrc":"","packageJsonExists":false,"enginesNode":"","nvmrcIsSymlink":false,"executable":true,"blockedReason":""}}'
        elif [ "$2" = plan ] && [ "$3" = cleanup ]; then
          printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"plan","data":{"ok":true,"schemaVersion":1,"action":"cleanup","targetType":"cleanup","subject":"npm-cache-clean","value":"","requiresConfirmation":true,"executeSupported":true,"externalWrite":false,"paths":["/test/cache"],"planToken":"token-1"}}'
        elif [ "$2" = execute ]; then
          printf '{"ok":true,"schemaVersion":1,"command":"execute","data":{"operationId":"op-1","action":"%s","subject":"%s","exitCode":0,"status":"ok","logFile":"/test/logs/op-1.log"}}\n' "$3" "$4"
        else
          exit 64
        fi
        """#
        try Data(contents.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let client = NodeManagerClient(
            runner: ProcessRunner(),
            environmentResolver: NodeEnvironmentResolver(homeDirectory: manager)
        )
        let request = NodeActionRequest(
            action: .writeProjectNVMRC,
            subject: "/test/project",
            value: "v22.14.0"
        )
        let plan = try await client.plan(request, managerDirectory: manager)
        let result = try await client.execute(plan, managerDirectory: manager)

        XCTAssertTrue(plan.canExecute)
        XCTAssertEqual(result.operationId, "op-1")
        let calls = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(calls.contains("plan|project-nvmrc|/test/project|v22.14.0|0|"))
        XCTAssertTrue(calls.contains("execute|project-nvmrc|/test/project|v22.14.0|1|1"))

        let cleanupPlan = try await client.plan(
            .init(action: .cleanup, subject: "npm-cache-clean"),
            managerDirectory: manager
        )
        let cleanupResult = try await client.execute(cleanupPlan, managerDirectory: manager)
        XCTAssertEqual(cleanupResult.action, "cleanup")
        let updatedCalls = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(updatedCalls.contains("execute|cleanup|npm-cache-clean|token-1|1|"))
    }
}
