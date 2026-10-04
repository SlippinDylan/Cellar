import Darwin
import XCTest
@testable import Cellar

final class NodeManagerClientTests: XCTestCase {
    func testFrozenUninstallVerificationErrorWithoutCodeKeepsUnknownReason() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarFrozenVerification-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let response = #"{"ok":false,"schemaVersion":1,"command":"execute","error":{"operationId":"fixture","action":"uninstall","subject":"example","exitCode":0,"status":"failed","detail":"post-uninstall-state-unavailable","logFile":"/private/fixture"}}"#
        let script = "#!/bin/bash\nprintf '%s\\n' '\(response)'\nexit 1\n"
        try Data(script.utf8).write(to: root.appending(path: "main.sh"))
        let client = NodeManagerClient(runner: ProcessRunner(), environmentResolver: NodeEnvironmentResolver(homeDirectory: root))
        do {
            let _: NodeOperationResult = try await client.request("execute", arguments: ["uninstall", "example"], managerDirectory: root,
                                                                 environment: ["HOME": root.path, "PATH": "/usr/bin:/bin", "NODE_MANAGER_ALLOW_JSON_EXECUTE": "1"])
            XCTFail("Expected a finite verification failure")
        } catch BridgeError.managerFailure(let code, _) {
            XCTAssertEqual(code, "post-uninstall-state-unavailable")
            XCTAssertEqual(ActivityItemReason(error: BridgeError.managerFailure(code: code, detail: nil)), .stateUnavailable)
        }
        for error in [
            #"{"action":"uninstall","exitCode":1,"status":"failed","detail":"post-uninstall-state-unavailable"}"#,
            #"{"action":"uninstall","exitCode":0,"status":"failed","detail":"npm-uninstall-failed"}"#,
            #"{"message":"missing code"}"#
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(ManagerErrorPayload.self, from: Data(error.utf8)))
        }
    }

    func testOutdatedUsesOriginalSystemPathsEvenWhenNVMHasTheSameVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarExactNodeTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let systemBin = root.appending(path: "system/bin")
        let nvmBin = root.appending(path: ".nvm/versions/node/v24.0.0/bin")
        for bin in [systemBin, nvmBin] {
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            for name in ["node", "npm"] {
                let file = bin.appending(path: name)
                try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
        }
        let log = root.appending(path: "calls.log")
        let script = #"""
        #!/bin/bash
        printf '%s|%s\n' "$2" "$PATH" >> '\#(log.path)'
        case "$2" in
          summary)
            printf '{"ok":true,"schemaVersion":1,"command":"summary","data":{"nodePath":"%s","npmPath":"%s","nodeVersion":"v24.0.0","npmVersion":"11.0.0","nvmLoaded":false,"globalPrefix":"/fixture","globalRoot":"/fixture/lib","registry":"https://fixture.invalid"}}\n' "$(command -v node)" "$(command -v npm)"
            ;;
          outdated)
            printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"outdated","data":{"example":{"current":"1.0.0","wanted":"1.0.0","latest":"2.0.0"}}}'
            ;;
          *) exit 2 ;;
        esac
        """#
        try Data(script.utf8).write(to: root.appending(path: "main.sh"))
        let summary = NodeSummary(nodePath: systemBin.appending(path: "node").path, npmPath: systemBin.appending(path: "npm").path,
                                  nodeVersion: "v24.0.0", npmVersion: "11.0.0", nvmLoaded: false,
                                  globalPrefix: "/fixture", globalRoot: "/fixture/lib", registry: "https://fixture.invalid")
        let client = NodeManagerClient(runner: ProcessRunner(), environmentResolver: NodeEnvironmentResolver(homeDirectory: root))
        let outdated = try await client.loadOutdatedPackages(managerDirectory: root, summary: summary)
        XCTAssertEqual(outdated["example"]?.latest, "2.0.0")
        let calls = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(calls.contains("summary|\(systemBin.path):"))
        XCTAssertTrue(calls.contains("outdated|\(systemBin.path):"))
        XCTAssertFalse(calls.contains(nvmBin.path))
        try FileManager.default.removeItem(at: systemBin.appending(path: "node"))
        do {
            _ = try await client.loadOutdatedPackages(managerDirectory: root, summary: summary)
            XCTFail("A missing original executable must not fall through to another Node")
        } catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "node-environment-changed") }
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), calls)
    }

    func testKeepsCoreNodeDataWhenOutdatedCheckFails() async throws {
        let manager = FileManager.default.temporaryDirectory
            .appending(path: "CellarNodeManagerClientTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: manager, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: manager) }

        let script = manager.appending(path: "main.sh")
        let log = manager.appending(path: "calls.log")
        let bin = manager.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["node", "npm"] {
            let entry = bin.appending(path: name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: entry)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entry.path)
        }
        let contents = #"""
        #!/bin/bash
        printf '%s\n' "$2" >> '\#(log.path)'
        case "$2" in
          summary)
            printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"summary","data":{"nodePath":"\#(bin.appending(path: "node").path)","npmPath":"\#(bin.appending(path: "npm").path)","nodeVersion":"v24.0.0","npmVersion":"11.0.0","nvmLoaded":false,"globalPrefix":"/test","globalRoot":"/test/lib/node_modules","registry":"https://registry.npmjs.org/"}}'
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

        let client = NodeManagerClient(runner: ProcessRunner(), environmentResolver: NodeEnvironmentResolver(homeDirectory: manager))
        let core = try await client.loadSnapshot(managerDirectory: manager, includingOutdated: false)
        XCTAssertEqual(core.summary.nodeVersion, "v24.0.0")
        XCTAssertEqual(core.packages.count, 1)
        let before = try String(contentsOf: log, encoding: .utf8)
        XCTAssertFalse(before.contains("outdated"))
        let changedEnvironment = NodeSummary(nodePath: "/different/node", npmPath: core.summary.npmPath,
                                            nodeVersion: core.summary.nodeVersion, npmVersion: core.summary.npmVersion,
                                            nvmLoaded: false, globalPrefix: core.summary.globalPrefix,
                                            globalRoot: core.summary.globalRoot, registry: core.summary.registry)
        do {
            _ = try await client.loadOutdatedPackages(managerDirectory: manager, summary: changedEnvironment)
            XCTFail("A stale environment must not reach npm outdated")
        } catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "node-environment-changed") }
        let afterMismatch = try String(contentsOf: log, encoding: .utf8)
        XCTAssertFalse(afterMismatch.contains("outdated"))
        do {
            _ = try await client.loadOutdatedPackages(managerDirectory: manager, summary: core.summary)
            XCTFail("Expected isolated outdated failure")
        } catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "npm-outdated-failed") }
        XCTAssertEqual(core.summary.npmVersion, "11.0.0")
        XCTAssertEqual(core.packages.first?.installedVersion, "1.0.0")
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
        let project = manager.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let contents = #"""
        #!/bin/bash
        printf '%s|%s|%s|%s|%s|%s\n' "$2" "${3:-}" "${4:-}" "${5:-}" "${NODE_MANAGER_ALLOW_JSON_EXECUTE:-}" "${NODE_MANAGER_ALLOW_PROJECT_WRITE:-}" >> '\#(log.path)'
        if [ "$2" = plan ] && [ "$3" = project-nvmrc ]; then
          printf '{"ok":true,"schemaVersion":1,"command":"plan","data":{"ok":true,"schemaVersion":1,"action":"project-nvmrc","targetType":"project-nvmrc","subject":"%s","value":"v22.14.0","requiresConfirmation":true,"executeSupported":true,"externalWrite":true,"pathExists":true,"pathIsDirectory":true,"nvmrcPath":"%s/.nvmrc","currentNvmrc":"","packageJsonExists":false,"enginesNode":"","nvmrcIsSymlink":false,"executable":true,"blockedReason":""}}\n' "$4" "$4"
        elif [ "$2" = plan ] && [ "$3" = cleanup ]; then
          printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"plan","data":{"ok":true,"schemaVersion":1,"action":"cleanup","targetType":"cleanup","subject":"npm-cache-clean","value":"","requiresConfirmation":true,"executeSupported":true,"externalWrite":false,"paths":["/test/cache"],"planToken":"token-1"}}'
        elif [ "$2" = execute ]; then
          if [ "$3" = project-nvmrc ]; then printf '%s\n' "$5" > "$4/.nvmrc"; fi
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
            subject: project.path,
            value: "v22.14.0"
        )
        let plan = try await client.plan(request, managerDirectory: manager)
        let result = try await client.execute(plan, managerDirectory: manager)

        XCTAssertTrue(plan.canExecute)
        XCTAssertEqual(result.operationId, "op-1")
        let calls = try String(contentsOf: log, encoding: .utf8)
        let canonical = try XCTUnwrap(realpath(project.path, nil))
        defer { free(canonical) }
        XCTAssertTrue(calls.contains("plan|project-nvmrc|\(String(cString: canonical))|v22.14.0|0|"))
        XCTAssertTrue(calls.contains("execute|project-nvmrc|\(String(cString: canonical))|v22.14.0|1|1"))
        XCTAssertEqual(result.batchItemStatus, .succeeded)

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
