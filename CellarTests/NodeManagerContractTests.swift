import XCTest
@testable import Cellar

final class NodeManagerContractTests: XCTestCase {
    func testUpdatePlanRequiresAnExactBehindTargetAndKeepsScopedPackageParsing() throws {
        for target in ["2.0.0", "1.0.0", "0.5.0", "git"] {
            let payload = try JSONDecoder().decode(NodeActionPlanPayload.self, from: Data("{\"action\":\"update-latest\",\"packageName\":\"@scope/example\",\"installedVersion\":\"1.0.0\",\"targetVersion\":\"\(target)\",\"executeSupported\":true}".utf8))
            let plan = NodeActionPlan(id: UUID(), request: .init(action: .updatePackage, subject: "@scope/example"), payload: payload, generatedAt: Date())
            XCTAssertEqual(plan.canExecute, target == "2.0.0")
            XCTAssertEqual(plan.exactUpdateSpec, target == "2.0.0" ? "@scope/example@2.0.0" : nil)
        }
        let missing = try JSONDecoder().decode(NodeActionPlanPayload.self, from: Data(#"{"action":"update-latest","executeSupported":true}"#.utf8))
        let plan = NodeActionPlan(id: UUID(), request: .init(action: .updatePackage, subject: "example"), payload: missing, generatedAt: Date())
        XCTAssertFalse(plan.canExecute)
        XCTAssertNil(plan.exactUpdateSpec)
    }

    func testUpdateVerificationUnknownIsNotSuccessAndRetainsActualExitCode() {
        let result = NodeOperationResult(operationId: "fixture", action: NodeAction.updatePackage.rawValue, subject: "example", exitCode: 0,
                                         status: "unknown", logFile: "", detail: "update-verification-unavailable", residues: nil)
        XCTAssertEqual(result.batchItemStatus, .unknown)
        let failed = NodeOperationResult(operationId: "fixture", action: NodeAction.updatePackage.rawValue, subject: "example", exitCode: 7,
                                         status: "unknown", logFile: "", detail: nil, residues: nil)
        XCTAssertEqual(failed.batchItemStatus, .failed)
    }
    func testDecodesActualUninstallResidueWarningResponse() throws {
        let result = try JSONDecoder().decode(ManagerEnvelope<NodeOperationResult>.self, from: Data(nodeUninstallResidueResponse.utf8))
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.data?.action, "uninstall")
        XCTAssertEqual(result.data?.exitCode, 0)
        XCTAssertEqual(result.data?.status, "warn")
        XCTAssertEqual(result.data?.detail, "residue-detected")
        XCTAssertEqual(result.data?.residues?.directories, ["/private/fake/lib/node_modules/one"])
        XCTAssertEqual(result.data?.residues?.bins, ["/private/fake/bin/one"])
        XCTAssertEqual(result.data?.batchItemStatus, .partiallySucceeded)
    }

    func testUninstallWarningRequiresSuccessfulRemovalAndKnownResidueDetail() throws {
        for (original, changed) in [("\"exitCode\":0", "\"exitCode\":7"),
                                    ("\"detail\":\"residue-detected\"", "\"detail\":\"still-installed\""),
                                    ("\"action\":\"uninstall\"", "\"action\":\"update-latest\"")] {
            let json = nodeUninstallResidueResponse.replacingOccurrences(of: original, with: changed)
            let result = try JSONDecoder().decode(ManagerEnvelope<NodeOperationResult>.self, from: Data(json.utf8))
            XCTAssertEqual(result.data?.batchItemStatus, .failed)
        }
    }
    func testDecodesSummaryEnvelope() throws {
        let json = #"{"ok":true,"schemaVersion":1,"command":"summary","data":{"nodePath":"/opt/node","npmPath":"/opt/npm","nodeVersion":"v24.0.0","npmVersion":"11.0.0","nvmLoaded":false,"globalPrefix":"/opt","globalRoot":"/opt/lib/node_modules","registry":"https://registry.npmjs.org/"}}"#

        let envelope = try JSONDecoder().decode(
            ManagerEnvelope<NodeSummary>.self,
            from: Data(json.utf8)
        )

        XCTAssertTrue(envelope.ok)
        XCTAssertEqual(envelope.schemaVersion, 1)
        XCTAssertEqual(envelope.data?.nodeVersion, "v24.0.0")
        XCTAssertNil(envelope.error)
    }

    func testDecodesPackageInventoryWithMissingDependencies() throws {
        let json = #"{"ok":true,"schemaVersion":1,"command":"packages","data":{"name":"lib"}}"#
        let envelope = try JSONDecoder().decode(
            ManagerEnvelope<NodePackageInventory>.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(envelope.data?.dependencies?.count, nil)
    }
}

let nodeUninstallResidueResponse = #"{"ok":true,"schemaVersion":1,"command":"execute","data":{"operationId":"uninstall-one","action":"uninstall","subject":"one","packageName":"one","installedVersion":"1.0.0","exitCode":0,"status":"warn","detail":"residue-detected","logFile":"/private/fake/log","residueCleanupPerformed":false,"cleanedResidues":0,"failedResidueCleanups":0,"residues":{"directories":["/private/fake/lib/node_modules/one"],"bins":["/private/fake/bin/one"]}}}"#

private final class SourceNodeManagerFixture {
    let root: URL
    let manager: URL
    let bin: URL
    let globalRoot: URL
    let client: NodeManagerClient

    init() throws {
        let temporary = URL(filePath: "/private/tmp/CellarSourceCleanup-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        root = temporary
        manager = root.appending(path: "manager")
        bin = root.appending(path: ".nvm/versions/node/v24.0.0/bin")
        globalRoot = root.appending(path: "prefix/lib/node_modules")
        client = NodeManagerClient(runner: ProcessRunner(), environmentResolver: NodeEnvironmentResolver(homeDirectory: root))
        for directory in [manager, bin, globalRoot, root.appending(path: "prefix/bin"), root.appending(path: ".nvm/alias")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let source = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "scripts/node-manager")
        let manifest = try String(contentsOf: source.appending(path: "app-bundle-manifest.txt"), encoding: .utf8)
        for path in manifest.split(separator: "\n").map(String.init) where !path.hasPrefix("#") && !path.isEmpty {
            let destination = manager.appending(path: path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source.appending(path: path), to: destination)
        }
        try Data("v24.0.0\n".utf8).write(to: root.appending(path: ".nvm/alias/default"))
        try tool("node", "#!/bin/sh\nprintf 'v24.0.0\\n'\n")
        try tool("npm", #"""
        #!/bin/bash
        case "$1" in
          root) printf '%s\n' "$HOME/prefix/lib/node_modules" ;;
          prefix) printf '%s\n' "$HOME/prefix" ;;
          config)
            case "$2:$3" in
              get:cache) printf '%s\n' "$HOME/.npm" ;;
              get:devdir) printf 'undefined\n' ;;
              *) exit 23 ;;
            esac ;;
          cache)
            if [ "$2" = verify ] && [ -f "$HOME/fail-verify" ]; then exit 29; fi ;;
          *) exit 97 ;;
        esac
        """#)
        try tool("rm", #"""
        #!/bin/bash
        last="${@: -1}"
        if [ -f "$HOME/fail-path" ] && [ "$last" = "$(cat "$HOME/fail-path")" ]; then
          /bin/rm -f "$last/one"
          exit 19
        fi
        if [ -f "$HOME/change-path" ]; then
          changed="$(cat "$HOME/change-path")"
          /bin/rm -f "$HOME/change-path" "$changed"
          printf replacement > "$changed"
        fi
        exec /bin/rm "$@"
        """#)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func tool(_ name: String, _ contents: String) throws {
        let file = bin.appending(path: name)
        try Data(contents.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    func link(_ name: String, target: String) throws -> URL {
        let path = root.appending(path: "prefix/bin/\(name)")
        try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: target)
        return path
    }

    func plan(_ target: String) async throws -> NodeActionPlan {
        try await client.plan(.init(action: .cleanup, subject: target), managerDirectory: manager)
    }

    var environment: [String: String] {
        ["HOME": root.path, "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin", "NVM_DIR": root.appending(path: ".nvm").path,
         "NODE_MANAGER_ALLOW_JSON_EXECUTE": "1"]
    }
}

extension NodeManagerContractTests {
    func testActualSourceOrphanEnumerationOrderIsStableAcrossConfirmation() async throws {
        for failSecond in [false, true] {
            let fixture = try SourceNodeManagerFixture()
            for name in ["a", "b", "c"] { _ = try fixture.link(name, target: "../lib/node_modules/missing/\(name).js") }
            try fixture.tool("find", #"""
            #!/bin/bash
            if [ "$1" = "$HOME/prefix/bin" ]; then
              if [ -f "$HOME/reverse-find" ]; then
                /usr/bin/find "$@" | LC_ALL=C /usr/bin/sort -r
              else
                /usr/bin/find "$@" | LC_ALL=C /usr/bin/sort
              fi
            else
              exec /usr/bin/find "$@"
            fi
            """#)
            let plan = try await fixture.plan("orphan-bins")
            let paths = try XCTUnwrap(plan.payload.paths)
            XCTAssertEqual(paths, paths.sorted())
            try Data().write(to: fixture.root.appending(path: "reverse-find"))
            if failSecond { try Data(paths[1].utf8).write(to: fixture.root.appending(path: "fail-path")) }
            let operation = try await fixture.client.execute(plan, managerDirectory: fixture.manager)
            XCTAssertEqual(operation.cleanupItems?.map(\.path), paths)
            XCTAssertEqual(operation.cleanupItems?.map(\.status), failSecond ? [.removed, .failed, .notAttempted] : [.removed, .removed, .removed])
            XCTAssertEqual(operation.batchItemStatus, failSecond ? .partiallySucceeded : .succeeded)
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths[0]))
            if failSecond {
                XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: paths[1]))
                XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: paths[2]))
            }
        }
    }

    func testActualSourceForeignDanglingAndNonDirectoryAncestorsRemainExcluded() async throws {
        let fixture = try SourceNodeManagerFixture()
        let owned = try fixture.link("npm-owned", target: "../lib/node_modules/missing/bin.js")
        let foreign = fixture.root.appending(path: "foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: foreign.appending(path: "current"), withDestinationURL: foreign.appending(path: "removed-version"))
        try Data("regular file".utf8).write(to: foreign.appending(path: "not-directory"))
        let dangling = try fixture.link("foreign-dangling", target: foreign.appending(path: "current/bin/tool").path)
        let nonDirectory = try fixture.link("foreign-file", target: foreign.appending(path: "not-directory/bin/tool").path)
        let plan = try await fixture.plan("orphan-bins")
        XCTAssertEqual(plan.payload.paths, [owned.path])
        let operation = try await fixture.client.execute(plan, managerDirectory: fixture.manager)
        XCTAssertEqual(operation.cleanupItems?.map(\.status), [.removed])
        XCTAssertEqual(operation.batchItemStatus, .succeeded)
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: dangling.path))
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: nonDirectory.path))
    }

    func testActualSourceOrphanPlanOnlySelectsCurrentNPMTargets() async throws {
        let fixture = try SourceNodeManagerFixture()
        let plain = try fixture.link("plain", target: "../lib/node_modules/missing/bin/tool.js")
        let scoped = try fixture.link("scoped", target: fixture.globalRoot.appending(path: "@scope/missing/bin/tool.js").path)
        _ = try fixture.link("unrelated", target: "../other/missing")
        _ = try fixture.link("other-node", target: fixture.root.appending(path: "another/lib/node_modules/pkg/bin.js").path)
        _ = try fixture.link("sibling-root", target: fixture.globalRoot.path + "-other/pkg/bin.js")
        _ = try fixture.link("dot-escape", target: "../lib/node_modules/../../other/pkg/bin.js")
        try FileManager.default.createSymbolicLink(at: fixture.globalRoot.appending(path: "escaped"), withDestinationURL: fixture.root)
        _ = try fixture.link("escaped", target: "../lib/node_modules/escaped/missing/bin.js")
        _ = try fixture.link("package-only", target: "../lib/node_modules/missing")
        let spaced = try fixture.link("with space", target: "../lib/node_modules/missing/bin/tool name.js")
        let plan = try await fixture.plan("orphan-bins")
        XCTAssertEqual(Set(plan.payload.paths ?? []), Set([plain.path, scoped.path, spaced.path]))
        let operation = try await fixture.client.execute(plan, managerDirectory: fixture.manager)
        XCTAssertEqual(operation.batchItemStatus, .succeeded)
        XCTAssertEqual(operation.cleanupItems?.count, 3)
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.root.appending(path: "prefix/bin/unrelated").path))
    }

    func testActualSourceOrphanReplacementAndConfigurationDriftRejectBeforeWrite() async throws {
        for mutation in ["file", "target", "valid", "root", "bin"] {
            let fixture = try SourceNodeManagerFixture()
            let link = try fixture.link("one", target: "../lib/node_modules/missing/bin.js")
            let plan = try await fixture.plan("orphan-bins")
            switch mutation {
            case "file":
                try FileManager.default.removeItem(at: link)
                try Data("replacement".utf8).write(to: link)
            case "target":
                try FileManager.default.removeItem(at: link)
                _ = try fixture.link("one", target: "../lib/node_modules/other/bin.js")
            case "valid":
                try FileManager.default.createDirectory(at: fixture.globalRoot.appending(path: "missing"), withIntermediateDirectories: true)
                try Data("restored".utf8).write(to: fixture.globalRoot.appending(path: "missing/bin.js"))
            case "root":
                try FileManager.default.moveItem(at: fixture.globalRoot, to: fixture.globalRoot.appendingPathExtension("old"))
                try FileManager.default.createDirectory(at: fixture.globalRoot, withIntermediateDirectories: true)
            default:
                try fixture.tool("npm", "#!/bin/sh\ncase \"$1\" in root) printf '%s\\n' \"$HOME/prefix/lib/node_modules\" ;; prefix) printf '%s\\n' \"$HOME/other\" ;; esac\n")
                try FileManager.default.createDirectory(at: fixture.root.appending(path: "other/bin"), withIntermediateDirectories: true)
            }
            do {
                _ = try await fixture.client.execute(plan, managerDirectory: fixture.manager)
                XCTFail("Changed \(mutation) must reject")
            } catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "plan-stale") }
            XCTAssertTrue(FileManager.default.fileExists(atPath: link.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
        }
    }

    func testActualSourceCleanupRetainsPartialUnknownAndUnattemptedFacts() async throws {
        for failureIndex in [0, 1] {
            let fixture = try SourceNodeManagerFixture()
            for path in ["Library/Caches/node-gyp", ".npm/node-gyp", ".node-gyp"] {
                let directory = fixture.root.appending(path: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for file in ["one", "two"] { try Data(file.utf8).write(to: directory.appending(path: file)) }
            }
            let plan = try await fixture.plan("node-gyp-cache")
            let paths = try XCTUnwrap(plan.payload.paths)
            XCTAssertEqual(paths.count, 3)
            try Data(paths[failureIndex].utf8).write(to: fixture.root.appending(path: "fail-path"))
            let operation = try await fixture.client.execute(plan, managerDirectory: fixture.manager)
            XCTAssertEqual(operation.batchItemStatus, failureIndex == 0 ? .unknown : .partiallySucceeded)
            XCTAssertEqual(operation.status, failureIndex == 0 ? "unknown" : "partial")
            let items = try XCTUnwrap(operation.cleanupItems)
            XCTAssertEqual(items.map(\.status), failureIndex == 0 ? [.unknown, .notAttempted, .notAttempted] : [.removed, .unknown, .notAttempted])
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths[failureIndex] + "/one"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths[failureIndex] + "/two"))
            XCTAssertEqual(operation.exitCode, 1)
        }
    }

    func testActualSourceOrphanUnlinkFailureKeepsEarlierRemovalAndLaterLink() async throws {
        let fixture = try SourceNodeManagerFixture()
        for name in ["one", "two", "three"] { _ = try fixture.link(name, target: "../lib/node_modules/missing/\(name).js") }
        let plan = try await fixture.plan("orphan-bins")
        let paths = try XCTUnwrap(plan.payload.paths)
        try Data(paths[1].utf8).write(to: fixture.root.appending(path: "fail-path"))
        let operation = try await fixture.client.execute(plan, managerDirectory: fixture.manager)
        XCTAssertEqual(operation.cleanupItems?.map(\.status), [.removed, .failed, .notAttempted])
        XCTAssertEqual(operation.batchItemStatus, .partiallySucceeded)
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: paths[1]))
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: paths[2]))
    }

    func testActualSourcePerCandidateReplacementIsRetainedAfterEarlierRemoval() async throws {
        let fixture = try SourceNodeManagerFixture()
        for name in ["one", "two", "three"] { _ = try fixture.link(name, target: "../lib/node_modules/missing/\(name).js") }
        let plan = try await fixture.plan("orphan-bins")
        let paths = try XCTUnwrap(plan.payload.paths)
        try Data(paths[1].utf8).write(to: fixture.root.appending(path: "change-path"))
        let operation = try await fixture.client.execute(plan, managerDirectory: fixture.manager)
        XCTAssertEqual(operation.cleanupItems?.map(\.status), [.removed, .retained, .notAttempted])
        XCTAssertEqual(operation.batchItemStatus, .partiallySucceeded)
        XCTAssertEqual(try String(contentsOfFile: paths[1], encoding: .utf8), "replacement")
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: paths[2]))
    }

    func testActualSourceUnreadableLinkScanIsUnavailableRatherThanEmpty() async throws {
        let fixture = try SourceNodeManagerFixture()
        _ = try fixture.link("one", target: "../lib/node_modules/missing/bin.js")
        // A fake Ruby entry injects an actual IO exception only at the attribution reader.
        try fixture.tool("ruby", #"""
        #!/bin/bash
        case "${2:-}" in
          *"File.readlink(link)"*) exit 2 ;;
        esac
        exec /usr/bin/ruby "$@"
        """#)
        do {
            _ = try await fixture.plan("orphan-bins")
            XCTFail("Unreadable ownership must fail the scan")
        } catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "cleanup-plan-unavailable") }
    }

    func testCleanupFailureRecoveryRejectsInvalidOrMismatchedEvidence() async throws {
        let fixture = try SourceNodeManagerFixture()
        _ = try fixture.link("one", target: "../lib/node_modules/missing/bin.js")
        let plan = try await fixture.plan("orphan-bins")
        let path = try XCTUnwrap(plan.payload.paths?.first)
        let error: [String: Any] = ["code": "cleanup-incomplete", "operationId": "fixture", "action": "cleanup", "subject": "orphan-bins",
                                    "exitCode": 1, "status": "unknown", "logFile": "", "cleanupItems": [["path": path, "status": "unknown", "reason": "deletion-incomplete"]]]
        var invalid: [[String: Any]] = []
        for key in ["code", "operationId", "cleanupItems"] { var value = error; value.removeValue(forKey: key); invalid.append(value) }
        for (key, value) in [("action", "registry-delete"), ("subject", "node-gyp-cache"), ("status", "ok")] {
            var changed = error; changed[key] = value; invalid.append(changed)
        }
        for items in [ [["path": path, "status": "bogus", "reason": "removed"]],
                       [["path": path, "status": "removed", "reason": "deletion-incomplete"]],
                       [["path": path + "-other", "status": "unknown", "reason": "deletion-incomplete"]], [] ] {
            var changed = error; changed["cleanupItems"] = items; invalid.append(changed)
        }
        for value in invalid {
            let data = try JSONSerialization.data(withJSONObject: ["ok": false, "schemaVersion": 1, "command": "execute", "error": value])
            let payload = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "'", with: "'\\''")
            try Data("#!/bin/bash\nprintf '%s\\n' '\(payload)'\nexit 1\n".utf8).write(to: fixture.manager.appending(path: "main.sh"))
            do {
                _ = try await fixture.client.execute(plan, managerDirectory: fixture.manager)
                XCTFail("Malformed failure must not become an operation result")
            } catch BridgeError.invalidOutput { }
        }
    }

    func testActualSourceOldNodeCleanupRetainsFirstRemovalWhenSecondUninstallFails() async throws {
        let fixture = try SourceNodeManagerFixture()
        let versions = fixture.root.appending(path: ".nvm/versions/node")
        for version in ["v18.0.0", "v20.0.0", "v22.0.0", "v24.0.0"] {
            let bin = versions.appending(path: "\(version)/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let node = bin.appending(path: "node")
            try Data("#!/bin/sh\nprintf '\(version)\\n'\n".utf8).write(to: node)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
            let npm = bin.appending(path: "npm")
            try Data("#!/bin/sh\nprintf '%s\\n' '{\"dependencies\":{}}'\n".utf8).write(to: npm)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: npm.path)
        }
        let nvm = #"""
        nvm() {
          case "$1" in
            current) printf 'v24.0.0\n' ;;
            alias) printf 'default -> v24.0.0\n' ;;
            uninstall)
              if [ "$2" = v20.0.0 ]; then return 27; fi
              /bin/rm -rf "$NVM_DIR/versions/node/$2" ;;
            *) return 91 ;;
          esac
        }
        """#
        try Data(nvm.utf8).write(to: fixture.root.appending(path: ".nvm/nvm.sh"))
        let plan = try await fixture.plan("nvm-old-versions")
        XCTAssertEqual(plan.payload.paths?.count, 3)
        let operation = try await fixture.client.execute(plan, managerDirectory: fixture.manager)
        XCTAssertEqual(operation.cleanupItems?.map(\.status), [.removed, .unknown, .notAttempted])
        XCTAssertEqual(operation.batchItemStatus, .partiallySucceeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: versions.appending(path: "v18.0.0").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: versions.appending(path: "v20.0.0").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: versions.appending(path: "v24.0.0").path))
    }

    func testActualSourceMissingGlobalRootIsAnEmptyReadAndCreationInvalidatesPlan() async throws {
        let fixture = try SourceNodeManagerFixture()
        try FileManager.default.removeItem(at: fixture.globalRoot)
        let plan = try await fixture.plan("orphan-bins")
        XCTAssertEqual(plan.payload.paths, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.globalRoot.path))
        try FileManager.default.createDirectory(at: fixture.globalRoot, withIntermediateDirectories: true)
        do {
            _ = try await fixture.client.execute(plan, managerDirectory: fixture.manager)
            XCTFail("Destination creation changes the confirmed empty state")
        } catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "plan-stale") }
    }

    func testActualSourceCacheCleanVerificationFailureKeepsCompletedPhase() async throws {
        let fixture = try SourceNodeManagerFixture()
        try Data().write(to: fixture.root.appending(path: "fail-verify"))
        let plan = try await fixture.plan("npm-cache-clean")
        let operation = try await fixture.client.execute(plan, managerDirectory: fixture.manager)
        XCTAssertEqual(operation.batchItemStatus, .partiallySucceeded)
        XCTAssertEqual(operation.cleanupItems?.first?.reason, .cacheCleanedVerificationFailed)
        XCTAssertEqual(operation.cleanupItems?.first?.status, .partial)
    }

    func testActualSourceEmptyCleanupSuccessAndUnrelatedFailureCode() async throws {
        let fixture = try SourceNodeManagerFixture()
        let plan = try await fixture.plan("orphan-bins")
        XCTAssertEqual(plan.payload.paths, [])
        let operation = try await fixture.client.execute(plan, managerDirectory: fixture.manager)
        XCTAssertEqual(operation.cleanupItems, [])
        XCTAssertEqual(operation.batchItemStatus, .succeeded)
        do {
            let _: NodeOperationResult = try await fixture.client.request("execute", arguments: ["registry-delete", "registry"], managerDirectory: fixture.manager, environment: fixture.environment)
            XCTFail("Fake npm config delete fails")
        } catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "operation-failed") }
    }
}
