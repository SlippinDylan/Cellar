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

    init(managerSource: URL? = nil, nonNVM: Bool = false) throws {
        let temporary = URL(filePath: "/private/tmp/CellarSourceCleanup-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        root = temporary
        manager = root.appending(path: "manager")
        bin = root.appending(path: nonNVM ? "detected/bin" : ".nvm/versions/node/v24.0.0/bin")
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
            try FileManager.default.copyItem(at: (managerSource ?? source).appending(path: path), to: destination)
        }
        try Data("v24.0.0\n".utf8).write(to: root.appending(path: ".nvm/alias/default"))
        try tool("node", "#!/bin/sh\nprintf 'v24.0.0\\n'\n")
        try tool("npm", #"""
        #!/bin/bash
        printf '%s|%s|%s\n' "$NODE_MANAGER_ALLOW_JSON_EXECUTE" "$0" "$*" >> "$HOME/npm-calls"
        case "$1" in
          --version|-v) [ ! -f "$HOME/npm-version-changed" ] || { printf '12.0.0\n'; exit; }; printf '11.0.0\n' ;;
          ls) printf '{"dependencies":{}}\n' ;;
          outdated) printf '{}\n' ;;
          root) printf '%s\n' "$HOME/prefix/lib/node_modules" ;;
          prefix) printf '%s\n' "$HOME/prefix" ;;
          config)
            case "$2:$3" in
              get:registry|get:@company:registry)
                if [ "$3" = @company:registry ] && [ -f "$HOME/fail-effective-scope" ]; then exit 23; fi
                key="$3"
                /usr/bin/ruby -e 'p=File.join(ENV.fetch("HOME"),".npmrc"); k=ARGV[0]; v=File.file?(p) ? File.readlines(p).map{|l| n,v=l.strip.split("=",2); v if n==k}.compact.last : nil; puts(v || (k=="registry" ? "https://registry.npmjs.org/" : "undefined"))' "$key" ;;
              get:userconfig) printf '%s/.npmrc\n' "$HOME" ;;
              get:globalconfig) printf '%s/global/npmrc\n' "$HOME" ;;
              get:cache) [ ! -f "$HOME/cache-path-changed" ] || { printf '%s/other-cache\n' "$HOME"; exit; }; printf '%s\n' "$HOME/.npm" ;;
              get:devdir) printf 'undefined\n' ;;
              set:*|delete:*)
                [ ! -f "$HOME/fail-registry-write" ] || exit 23
                /usr/bin/ruby -e 'p=File.join(ENV.fetch("HOME"),".npmrc"); a,k,v=ARGV; lines=File.file?(p) ? File.readlines(p).reject{|l| l.split("=",2).first.strip==k} : []; lines << "#{k}=#{v}\n" if a=="set"; File.write(p,lines.join)' "$2" "$3" "$4" ;;
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

    @MainActor
    func model() throws -> AppModel {
        try FileManager.default.createSymbolicLink(at: root.appending(path: "node-manager"), withDestinationURL: manager)
        let runner = ProcessRunner()
        let resolver = NodeEnvironmentResolver(homeDirectory: root)
        let service = SystemProbeService(runner: runner, installer: ManagerSnapshotInstaller(applicationSupportDirectory: root), nodeClient: client,
                                         shellClient: ShellManagerClient(runner: runner, environmentResolver: .init(homeDirectory: root)), environmentResolver: resolver)
        return AppModel(service: service, operationStore: OperationStore(), activityStore: ActivityStore(),
                        managerSnapshot: .init(version: "fixture", location: root.path, nodeAvailable: true, homebrewAvailable: false, shellAvailable: false))
    }

    func logInventory() throws -> URL {
        let logs = manager.appending(path: ".runtime/logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        for index in 0..<105 {
            let path = logs.appending(path: "fixture.log.\(index)")
            try Data("log".utf8).write(to: path)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10_000 - Double(index))], ofItemAtPath: path.path)
        }
        return logs
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
    @MainActor
    func testActualSourceLogsThroughAppModelWithoutNodeKeepExactRetentionAndOneUse() async throws {
        let fixture = try SourceNodeManagerFixture()
        // Keep executable barriers so the production resolver cannot fall back to real tools.
        for name in ["node", "npm"] {
            try fixture.tool(name, "#!/bin/sh\nprintf '%s|%s\\n' \"$0\" \"$*\" >> \"$HOME/unavailable-tool-calls\"\nexit 127\n")
        }
        let model = try fixture.model()
        do { _ = try await fixture.client.loadSnapshot(managerDirectory: fixture.manager); XCTFail("No npm must fail the actual core read") }
        catch { model.applyNodeReadResult(.failure(error)) }
        XCTAssertNil(model.node)
        XCTAssertTrue(model.nodeRefreshFailed)
        let logs = try fixture.logInventory()
        await model.prepareNodeAction(NodeMaintenanceAction.logs.request)
        let plan = try XCTUnwrap(model.nodePlan)
        XCTAssertEqual(plan.maintenanceCandidates, (99..<105).map { logs.appending(path: "fixture.log.\($0)").path })
        await model.executeNodePlan(confirmed: plan)
        let result = try XCTUnwrap(model.nodeActionResult)
        XCTAssertEqual(result.operation.action, "cleanup")
        XCTAssertEqual(result.operation.subject, "logs")
        XCTAssertFalse(result.operation.operationId.isEmpty)
        XCTAssertEqual(result.operation.exitCode, 0)
        XCTAssertEqual(result.operation.batchItemStatus, .succeeded)
        XCTAssertNil(result.postflightError)
        XCTAssertNil(model.nodeOperationError)
        XCTAssertTrue(model.nodeRefreshFailed)
        XCTAssertNil(model.node)
        XCTAssertEqual(model.activityStore?.summaries.first?.status, .succeeded)
        let remaining = try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)
        XCTAssertEqual(remaining.count, 100, "99 original logs and the genuine execution log remain")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.operation.logFile))
        for index in 0..<105 {
            XCTAssertEqual(FileManager.default.fileExists(atPath: logs.appending(path: "fixture.log.\(index)").path), index < 99)
        }
        await model.executeNodePlan(confirmed: plan)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil).count, 100)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appending(path: "unavailable-tool-calls").path))
    }

    @MainActor
    func testActualSourceLogDeletionFailureRetainsObservedChangesAndGenuineOperation() async throws {
        for failedIndex in [99, 101] {
            let fixture = try SourceNodeManagerFixture()
            for name in ["node", "npm"] { try fixture.tool(name, "#!/bin/sh\nexit 41\n") }
            try fixture.tool("rm", """
            #!/bin/bash
            last="${@: -1}"
            if [ "${last##*/}" = "fixture.log.\(failedIndex)" ]; then exit 19; fi
            exec /bin/rm "$@"
            """)
            let model = try fixture.model()
            do { _ = try await fixture.client.loadSnapshot(managerDirectory: fixture.manager); XCTFail("Broken npm must fail core read") }
            catch { model.applyNodeReadResult(.failure(error)) }
            _ = try fixture.logInventory()
            await model.prepareNodeAction(NodeMaintenanceAction.logs.request)
            let plan = try XCTUnwrap(model.nodePlan)
            await model.executeNodePlan(confirmed: plan)
            let result = try XCTUnwrap(model.nodeActionResult, "Actual failed cleanup must retain operation evidence")
            XCTAssertEqual(result.operation.action, "cleanup")
            XCTAssertEqual(result.operation.subject, "logs")
            XCTAssertFalse(result.operation.operationId.isEmpty)
            XCTAssertEqual(result.operation.exitCode, 1, "The real cleanup helper reports failure as1")
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.operation.logFile))
            let items = try XCTUnwrap(result.operation.cleanupItems)
            XCTAssertEqual(items.map(\.path), plan.maintenanceCandidates)
            XCTAssertEqual(items.map(\.status), (99..<105).map { $0 < failedIndex ? .removed : .unknown })
            XCTAssertEqual(result.operation.batchItemStatus, failedIndex == 99 ? .unknown : .partiallySucceeded)
            XCTAssertEqual(model.activityStore?.summaries.first?.status, failedIndex == 99 ? .unknown : .partiallySucceeded)
            XCTAssertNil(result.postflightError)
            XCTAssertNotNil(model.nodeOperationError)
            XCTAssertTrue(model.nodeRefreshFailed)
        }
    }

    func testLogFailureRecoveryRejectsMissingAndMismatchedOperationEvidence() throws {
        let original: [String: Any] = ["code": "logs-cleanup-failed", "operationId": "real-operation", "action": "cleanup", "subject": "logs", "exitCode": 1, "status": "failed", "logFile": "/fixture/log"]
        let legacy = Data(#"{"ok":false,"schemaVersion":1,"command":"logs-cleanup","error":{"code":"logs-cleanup-failed"}}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ManagerEnvelope<NodeOperationResult>.self, from: legacy).error?.cleanupOperation)
        let invalidChanges: [[String: Any]] = [["action": "install"], ["subject": "npm-cache-clean"], ["exitCode": 0], ["status": "ok"], ["operationId": ""], ["logFile": ""]]
        for changes in invalidChanges {
            let error = original.merging(changes) { _, new in new }
            let data = try JSONSerialization.data(withJSONObject: ["ok": false, "schemaVersion": 1, "command": "execute", "error": error])
            do {
                let decoded = try JSONDecoder().decode(ManagerEnvelope<NodeOperationResult>.self, from: data)
                XCTAssertNil(decoded.error?.cleanupOperation, "Mismatched or incomplete evidence cannot be recovered")
            } catch is DecodingError { }
        }
        for key in ["operationId", "exitCode", "logFile", "subject"] {
            var error = original
            error.removeValue(forKey: key)
            let data = try JSONSerialization.data(withJSONObject: ["ok": false, "schemaVersion": 1, "command": "execute", "error": error])
            do {
                let decoded = try JSONDecoder().decode(ManagerEnvelope<NodeOperationResult>.self, from: data)
                XCTAssertNil(decoded.error?.cleanupOperation, "Mismatched or incomplete evidence cannot be recovered")
            } catch is DecodingError { }
        }
    }

    func testActualSourceLogsExecuteRequiresGateAndLeavesStandaloneLegacyCommandIntact() async throws {
        let fixture = try SourceNodeManagerFixture()
        let logs = try fixture.logInventory()
        var environment = fixture.environment
        environment["NODE_MANAGER_ALLOW_JSON_EXECUTE"] = "0"
        let request = ProcessRequest(executableURL: URL(filePath: "/bin/bash"), arguments: [fixture.manager.appending(path: "main.sh").path, "--json", "execute", "cleanup", "logs", "100"], environment: environment, currentDirectoryURL: fixture.manager, timeout: .seconds(20))
        let refused = try await ProcessRunner().run(request)
        XCTAssertNotEqual(refused.terminationStatus, 0)
        XCTAssertTrue(refused.outputText.contains("json-execute-disabled"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil).count, 105)
        let legacy = try await ProcessRunner().run(.init(executableURL: URL(filePath: "/bin/bash"), arguments: [fixture.manager.appending(path: "main.sh").path, "--json", "logs-cleanup", "100"], environment: environment, currentDirectoryURL: fixture.manager, timeout: .seconds(20)))
        XCTAssertEqual(legacy.terminationStatus, 0)
        XCTAssertTrue(legacy.outputText.contains("logs-cleanup"))
        XCTAssertFalse(legacy.outputText.contains("operationId"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil).count, 100)
    }

    func testBundledAdapterPreservesOwnedCleanupPartialResultsAndForeignLinks() async throws {
        let bundled = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "Managers/node-manager")
        let fixture = try SourceNodeManagerFixture(managerSource: bundled)
        for name in ["a", "b", "c"] { _ = try fixture.link(name, target: "../lib/node_modules/missing/\(name).js") }
        let foreign = fixture.root.appending(path: "foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: foreign.appending(path: "current"), withDestinationURL: foreign.appending(path: "missing"))
        let unrelated = try fixture.link("unrelated", target: foreign.appending(path: "current/bin/tool").path)
        let sibling = try fixture.link("sibling", target: fixture.globalRoot.path + "-other/pkg/bin.js")
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
        XCTAssertEqual(paths, ["a", "b", "c"].map { fixture.root.appending(path: "prefix/bin/\($0)").path })
        try Data().write(to: fixture.root.appending(path: "reverse-find"))
        try Data(paths[1].utf8).write(to: fixture.root.appending(path: "fail-path"))
        let operation = try await fixture.client.execute(plan, managerDirectory: fixture.manager)
        XCTAssertEqual(operation.cleanupItems?.map(\.path), paths)
        XCTAssertEqual(operation.cleanupItems?.map(\.status), [.removed, .failed, .notAttempted])
        XCTAssertEqual(operation.status, "partial")
        XCTAssertEqual(operation.exitCode, 1)
        XCTAssertEqual(operation.batchItemStatus, .partiallySucceeded)
        for path in [paths[1], paths[2], unrelated.path, sibling.path] {
            XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: path))
        }
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: paths[0]))
    }

    func testBundledAdapterRetainsActualPartialDirectoryDeletionAsUnknown() async throws {
        let bundled = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "Managers/node-manager")
        let fixture = try SourceNodeManagerFixture(managerSource: bundled)
        let cache = fixture.root.appending(path: ".node-gyp")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        for name in ["one", "two"] { try Data(name.utf8).write(to: cache.appending(path: name)) }
        let plan = try await fixture.plan("node-gyp-cache")
        XCTAssertEqual(plan.payload.paths, [cache.path])
        try Data(cache.path.utf8).write(to: fixture.root.appending(path: "fail-path"))
        let operation = try await fixture.client.execute(plan, managerDirectory: fixture.manager)
        XCTAssertEqual(operation.cleanupItems?.map(\.status), [.unknown])
        XCTAssertEqual(operation.batchItemStatus, .unknown)
        XCTAssertEqual(operation.exitCode, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appending(path: "one").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appending(path: "two").path))
    }

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
            } catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, mutation == "bin" ? "node-environment-changed" : "plan-stale") }
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
        let original = fixture.manager.appending(path: "test-source-main.sh")
        try FileManager.default.copyItem(at: fixture.manager.appending(path: "main.sh"), to: original)
        for value in invalid {
            let data = try JSONSerialization.data(withJSONObject: ["ok": false, "schemaVersion": 1, "command": "execute", "error": value])
            let payload = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "'", with: "'\\''")
            let wrapper = "#!/bin/bash\nif [ \"$2\" = execute ]; then printf '%s\\n' '\(payload)'; exit 1; fi\nexec /bin/bash '\(original.path)' \"$@\"\n"
            try Data(wrapper.utf8).write(to: fixture.manager.appending(path: "main.sh"))
            let confirmed = try await fixture.plan("orphan-bins")
            do {
                _ = try await fixture.client.execute(confirmed, managerDirectory: fixture.manager)
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
        try Data().write(to: fixture.root.appending(path: "fail-registry-write"))
        do {
            let _: NodeOperationResult = try await fixture.client.request("execute", arguments: ["registry-delete", "registry"], managerDirectory: fixture.manager, environment: fixture.environment)
            XCTFail("Fake npm config delete fails")
        } catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "operation-failed") }
    }
}

extension NodeManagerContractTests {
    func testActualSourceRegistryNormalizationScopeAndNonNVMConfiguration() async throws {
        let fixture = try SourceNodeManagerFixture(nonNVM: true)
        let summary: NodeSummary = try await fixture.client.request("summary", managerDirectory: fixture.manager, environment: fixture.environment)
        XCTAssertFalse(summary.nvmLoaded)
        for input in ["https://registry.example.test", "https://registry.example.test/npm%2Fprivate", "http://localhost:8080/npm", "http://127.0.0.1:8080", "http://[::1]:8080/npm/"] {
            let expected = try XCTUnwrap(SourceConfiguration.registryURL(input)).absoluteString
            let plan = try await fixture.client.plan(.init(action: .setRegistry, subject: input), managerDirectory: fixture.manager, detectedSummary: summary)
            XCTAssertEqual(plan.request.subject, expected)
            let result = try await fixture.client.execute(plan, managerDirectory: fixture.manager)
            XCTAssertEqual(result.batchItemStatus, .succeeded)
            XCTAssertTrue(try String(contentsOf: fixture.root.appending(path: ".npmrc"), encoding: .utf8).contains("registry=\(expected)"))
            let scoped = try await fixture.client.plan(.init(action: .setScopeRegistry, subject: "@company", value: input), managerDirectory: fixture.manager, detectedSummary: summary)
            XCTAssertEqual(scoped.request.value, expected)
            let scopedResult = try await fixture.client.execute(scoped, managerDirectory: fixture.manager)
            XCTAssertEqual(scopedResult.batchItemStatus, .succeeded)
            let layers = try await fixture.client.scopeRegistryLayers("@company", summary: summary, managerDirectory: fixture.manager)
            XCTAssertEqual(layers.effective, expected)
            XCTAssertEqual(layers.user, expected)
            let removed = try await fixture.client.plan(.init(action: .deleteScopeRegistry, subject: "@company"), managerDirectory: fixture.manager, detectedSummary: summary)
            let removedResult = try await fixture.client.execute(removed, managerDirectory: fixture.manager)
            XCTAssertEqual(removedResult.batchItemStatus, .succeeded)
        }
        let unset = try await fixture.client.scopeRegistryLayers("@company", summary: summary, managerDirectory: fixture.manager)
        XCTAssertEqual(unset.effective, "undefined")
        XCTAssertEqual(unset.user, "undefined")
        let removed = try await fixture.client.plan(.init(action: .deleteRegistry), managerDirectory: fixture.manager, detectedSummary: summary)
        let removedResult = try await fixture.client.execute(removed, managerDirectory: fixture.manager)
        XCTAssertEqual(removedResult.batchItemStatus, .succeeded)
        let cache = try await fixture.client.plan(NodeMaintenanceAction.verify.request, managerDirectory: fixture.manager, detectedSummary: summary)
        let cacheResult = try await fixture.client.execute(cache, managerDirectory: fixture.manager)
        XCTAssertEqual(cacheResult.batchItemStatus, .succeeded)
        let clean = try await fixture.client.plan(NodeMaintenanceAction.npmCache.request, managerDirectory: fixture.manager, detectedSummary: summary)
        let cleanResult = try await fixture.client.execute(clean, managerDirectory: fixture.manager)
        XCTAssertEqual(cleanResult.batchItemStatus, .succeeded)
        let changedCache = try await fixture.client.plan(NodeMaintenanceAction.verify.request, managerDirectory: fixture.manager, detectedSummary: summary)
        try Data().write(to: fixture.root.appending(path: "cache-path-changed"))
        do { _ = try await fixture.client.execute(changedCache, managerDirectory: fixture.manager); XCTFail("Changed cache target must reject") }
        catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "plan-stale") }
        for action in [NodeAction.installPackage, .updatePackage, .uninstallPackage] {
            do {
                _ = try await fixture.client.plan(.init(action: action, subject: "example"), managerDirectory: fixture.manager, detectedSummary: summary)
                XCTFail("Readable non-nvm npm must not authorize package writes")
            } catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "node-environment-changed") }
        }
        let calls = try String(contentsOf: fixture.root.appending(path: "npm-calls"), encoding: .utf8)
        XCTAssertTrue(calls.split(separator: "\n").allSatisfy { $0.contains(fixture.bin.path + "/npm") })
        XCTAssertFalse(calls.contains("install example"))
    }

    func testActualSourceRegistryRejectsChangedExactEnvironmentAndGlobalConfiguration() async throws {
        for change in ["global-file", "global-inode", "npm-version", "npm-entry", "default"] {
            let fixture = try SourceNodeManagerFixture(nonNVM: true)
            let global = fixture.root.appending(path: "global/npmrc")
            try FileManager.default.createDirectory(at: global.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("registry=https://global.example.test/\n".utf8).write(to: global)
            let summary: NodeSummary = try await fixture.client.request("summary", managerDirectory: fixture.manager, environment: fixture.environment)
            let plan = try await fixture.client.plan(.init(action: .setRegistry, subject: "https://new.example.test"), managerDirectory: fixture.manager, detectedSummary: summary)
            switch change {
            case "global-file": try Data("registry=https://changed.example.test/\n".utf8).write(to: global)
            case "global-inode":
                try FileManager.default.moveItem(at: global, to: global.appendingPathExtension("old"))
                try Data("registry=https://global.example.test/\n".utf8).write(to: global)
            case "npm-version": try Data().write(to: fixture.root.appending(path: "npm-version-changed"))
            case "npm-entry": try FileManager.default.removeItem(at: fixture.bin.appending(path: "npm"))
            default: try Data("v22.0.0\n".utf8).write(to: fixture.root.appending(path: ".nvm/alias/default"))
            }
            do { _ = try await fixture.client.execute(plan, managerDirectory: fixture.manager); XCTFail("Changed confirmation: \(change)") }
            catch { XCTAssertTrue([ActivityItemReason.stateChanged, .stateUnavailable].contains(ActivityItemReason(error: error))) }
            XCTAssertFalse(try String(contentsOf: fixture.root.appending(path: "npm-calls"), encoding: .utf8).contains("|config set "))
        }
    }

    func testActualSourceRegistryURLPolicyMatchesAppAndNormalizesJSONEntryPoints() async throws {
        let fixture = try SourceNodeManagerFixture(nonNVM: true)
        for (input, accepted) in [
            ("https://registry.example.test", true), ("https://registry.example.test/npm%2fpath+one", true),
            (" https://registry.example.test/npm \n", true), ("\u{00A0}https://registry.example.test\u{00A0}", true), ("\u{000B}https://registry.example.test\u{000B}", true), ("https://registry.example.test/with\u{00A0}space", false), ("https://registry.example.test/with\u{000B}space", false), ("https://registry.example.test:65535/npm//", true),
            ("http://localhost:8080", true), ("http://127.0.0.1/npm", true), ("http://[::1]:8080/npm", true),
            ("http://registry.example.test/", false), ("http://localhost.example/", false), ("http://127.0.0.2/", false),
            ("https://user:secret@example.test/", false), ("https://example.test/?query", false), ("https://example.test/#fragment", false),
            ("https://example.test:0/", false), ("https://example.test:65536/", false), ("https://example.test:9999999999999/", false),
            ("https://example.test/%zz/", false), ("https://example.test/path space/", false), ("HTTPS://example.test/", false)
        ] {
            XCTAssertEqual(SourceConfiguration.registryURL(input) != nil, accepted, input)
            for action in [NodeAction.setRegistry, .setScopeRegistry] {
                let arguments = action == .setRegistry ? [action.rawValue, input] : [action.rawValue, "@company", input]
                do {
                    let payload: NodeActionPlanPayload = try await fixture.client.request("plan", arguments: arguments, managerDirectory: fixture.manager, environment: fixture.environment)
                    XCTAssertTrue(accepted, input)
                    XCTAssertTrue(payload.executeSupported ?? false)
                    XCTAssertEqual(action == .setRegistry ? payload.subject : payload.value, SourceConfiguration.registryURL(input)?.absoluteString)
                } catch { XCTAssertFalse(accepted, "\(input): \(error)") }
                do {
                    let operation: NodeOperationResult = try await fixture.client.request("execute", arguments: arguments, managerDirectory: fixture.manager, environment: fixture.environment)
                    XCTAssertTrue(accepted, input)
                    XCTAssertEqual(operation.batchItemStatus, .succeeded)
                    let contents = try String(contentsOf: fixture.root.appending(path: ".npmrc"), encoding: .utf8)
                    XCTAssertTrue(contents.contains(try XCTUnwrap(SourceConfiguration.registryURL(input)).absoluteString))
                } catch { XCTAssertFalse(accepted, "execute \(input): \(error)") }
            }
        }
    }
}

extension NodeManagerContractTests {
    func testSourceScopeReadBoundsAllDiscoveredLayersBeforeLayerReader() async throws {
        for location in [".npmrc", "global/npmrc", "prefix/.npmrc"] {
            let fixture = try SourceNodeManagerFixture()
            let file = fixture.root.appending(path: location)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 65, count: 65_537).write(to: file)
            try fixture.tool("ruby", #"""
            #!/bin/bash
            case "${2:-}" in *"File.foreach(config_file)"*) /usr/bin/touch "$HOME/layer-reader-ran" ;; esac
            exec /usr/bin/ruby "$@"
            """#)
            let summary: NodeSummary = try await fixture.client.request("summary", managerDirectory: fixture.manager, environment: fixture.environment)
            do { _ = try await fixture.client.scopeRegistryLayers("@company", summary: summary, managerDirectory: fixture.manager); XCTFail("Oversized \(location) must refuse scope read") }
            catch { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appending(path: "layer-reader-ran").path))
        }
    }

    func testSourceScopeReadRejectsLayerFailureAndConfigurationOrEnvironmentDrift() async throws {
        for mode in ["layer-failure", "effective-failure", "config-drift", "entry-drift"] {
            let fixture = try SourceNodeManagerFixture(nonNVM: true)
            try Data("@company:registry=https://scope.example.test/\n".utf8).write(to: fixture.root.appending(path: ".npmrc"))
            let summary: NodeSummary = try await fixture.client.request("summary", managerDirectory: fixture.manager, environment: fixture.environment)
            let initial = try await fixture.client.scopeRegistryLayers("@company", summary: summary, managerDirectory: fixture.manager)
            XCTAssertEqual(initial.user, "https://scope.example.test/")
            if mode == "effective-failure" { try Data().write(to: fixture.root.appending(path: "fail-effective-scope")) }
            else {
                try Data(mode.utf8).write(to: fixture.root.appending(path: "scope-mode"))
                try fixture.tool("ruby", #"""
                #!/bin/bash
                case "${2:-}" in
                  *"File.foreach(config_file)"*)
                    case "$(/bin/cat "$HOME/scope-mode")" in
                      layer-failure) /bin/mv "$3" "$3.removed" ;;
                      config-drift) printf '# changed\n' >> "$HOME/.npmrc" ;;
                      entry-drift) /usr/bin/touch "$HOME/npm-version-changed" ;;
                    esac ;;
                esac
                exec /usr/bin/ruby "$@"
                """#)
            }
            do { _ = try await fixture.client.scopeRegistryLayers("@company", summary: summary, managerDirectory: fixture.manager); XCTFail("Failed or mixed layer data must refuse: \(mode)") }
            catch { }
        }
    }

    @MainActor
    func testSourceSnapshotCapabilityIsRecordedAtReadAndWriteStillRevalidates() async throws {
        let fixture = try SourceNodeManagerFixture()
        let node = try await fixture.client.loadSnapshot(managerDirectory: fixture.manager)
        let runner = ProcessRunner()
        let resolver = NodeEnvironmentResolver(homeDirectory: fixture.root)
        let service = SystemProbeService(runner: runner, installer: .init(applicationSupportDirectory: fixture.root.appending(path: "support")),
            nodeClient: fixture.client, shellClient: .init(runner: runner, environmentResolver: .init(homeDirectory: fixture.root)), environmentResolver: resolver)
        let model = AppModel(service: service, operationStore: OperationStore())
        model.applyNodeReadResult(.success(node))
        let context = try XCTUnwrap(model.nodePackageEnvironment)
        try FileManager.default.removeItem(at: fixture.bin.appending(path: "npm"))
        XCTAssertEqual(model.nodePackageEnvironment, context, "UI reads consume the recorded fact without new filesystem IO")
        do { _ = try await fixture.client.planPackage(.init(name: "example", environment: context), action: .installPackage, managerDirectory: fixture.manager); XCTFail("Write preparation must revalidate missing npm") }
        catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "node-environment-changed") }
        model.applyNodeReadResult(.failure(BridgeError.invalidOutput("fixture read failed")))
        XCTAssertNil(model.nodePackageEnvironment)
    }
}

extension NodeManagerContractTests {
    func testSourceSnapshotDoesNotGrantCapabilityToSameVersionForeignEntries() async throws {
        for name in ["node", "npm"] {
            let fixture = try SourceNodeManagerFixture()
            let foreign = fixture.root.appending(path: "detected/bin/\(name)")
            try FileManager.default.createDirectory(at: foreign.deletingLastPathComponent(), withIntermediateDirectories: true)
            let entry = fixture.bin.appending(path: name)
            try FileManager.default.copyItem(at: entry, to: foreign)
            try FileManager.default.removeItem(at: entry)
            try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: foreign)
            let snapshot = try await fixture.client.loadSnapshot(managerDirectory: fixture.manager)
            XCTAssertEqual(snapshot.summary.nodeVersion, "v24.0.0")
            XCTAssertEqual(snapshot.summary.npmVersion, "11.0.0")
            XCTAssertNil(snapshot.packageEnvironment, "A same-version foreign \(name) entry remains readable but unsupported")
        }
    }
}

extension NodeManagerContractTests {
    func testSourceScopeLayerFailuresProduceFailedRawEnvelopes() async throws {
        let emptyFixture = try SourceNodeManagerFixture(nonNVM: true)
        try Data("@company:registry=\n".utf8).write(to: emptyFixture.root.appending(path: ".npmrc"))
        let summary: NodeSummary = try await emptyFixture.client.request("summary", managerDirectory: emptyFixture.manager, environment: emptyFixture.environment)
        let emptyLayers = try await emptyFixture.client.scopeRegistryLayers("@company", summary: summary, managerDirectory: emptyFixture.manager)
        XCTAssertEqual(emptyLayers.effective, "")
        XCTAssertEqual(emptyLayers.user, "")
        XCTAssertEqual(emptyLayers.project, "undefined")
        XCTAssertEqual(emptyLayers.global, "undefined")
        for effectiveFailure in [true, false] {
            let fixture = try SourceNodeManagerFixture(nonNVM: true)
            try Data("@company:registry=https://scope.example.test/\n".utf8).write(to: fixture.root.appending(path: ".npmrc"))
            if effectiveFailure { try Data().write(to: fixture.root.appending(path: "fail-effective-scope")) }
            else {
                try fixture.tool("ruby", #"""
                #!/bin/bash
                case "${2:-}" in *"File.foreach(config_file)"*) /bin/mv "$3" "$3.removed" ;; esac
                exec /usr/bin/ruby "$@"
                """#)
            }
            let result = try await ProcessRunner().run(.init(executableURL: URL(filePath: "/bin/bash"),
                arguments: [fixture.manager.appending(path: "main.sh").path, "--json", "plan", "scope-registry-delete", "@company"],
                environment: fixture.environment, currentDirectoryURL: fixture.manager))
            let envelope = try JSONDecoder().decode(ManagerEnvelope<NodeActionPlanPayload>.self, from: result.standardOutput)
            XCTAssertNotEqual(result.terminationStatus, 0)
            XCTAssertFalse(envelope.ok)
            XCTAssertNil(envelope.data)
            XCTAssertEqual(envelope.error?.code, "registry-state-unavailable")
        }
    }
}

extension NodeManagerContractTests {
    func testBundledRegistryNormalizesRawDefaultAndScopeWritesInNonNVMEnvironment() async throws {
        let source = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "Managers/node-manager")
        let fixture = try SourceNodeManagerFixture(managerSource: source, nonNVM: true)
        for input in ["\u{00A0}https://registry.example.test/npm%2fprivate+one\u{00A0}", "\u{000B}http://[::1]:8080/npm//\u{000B}"] {
            let expected = try XCTUnwrap(SourceConfiguration.registryURL(input)).absoluteString
            for action in [NodeAction.setRegistry, .setScopeRegistry] {
                let arguments = action == .setRegistry ? [action.rawValue, input] : [action.rawValue, "@company", input]
                let payload: NodeActionPlanPayload = try await fixture.client.request("plan", arguments: arguments, managerDirectory: fixture.manager, environment: fixture.environment)
                XCTAssertEqual(action == .setRegistry ? payload.subject : payload.value, expected)
                let operation: NodeOperationResult = try await fixture.client.request("execute", arguments: arguments, managerDirectory: fixture.manager, environment: fixture.environment)
                XCTAssertEqual(operation.batchItemStatus, .succeeded)
                let key = action == .setRegistry ? "registry" : "@company:registry"
                XCTAssertTrue(try String(contentsOf: fixture.root.appending(path: ".npmrc"), encoding: .utf8).contains("\(key)=\(expected)\n"))
            }
        }
        let summary: NodeSummary = try await fixture.client.request("summary", managerDirectory: fixture.manager, environment: fixture.environment)
        XCTAssertFalse(summary.nvmLoaded)
        XCTAssertFalse(summary.nodePath.contains("/.nvm/"))
        let plan = try await fixture.client.plan(.init(action: .setRegistry, subject: "https://registry.example.test"), managerDirectory: fixture.manager, detectedSummary: summary)
        let operation = try await fixture.client.execute(plan, managerDirectory: fixture.manager)
        XCTAssertEqual(operation.batchItemStatus, .succeeded)
        let layers = try await fixture.client.scopeRegistryLayers("@company", summary: summary, managerDirectory: fixture.manager)
        XCTAssertEqual(layers.user, "http://[::1]:8080/npm//")
    }

    func testBundledScopeReadPreservesSuccessfulEmptyAndRejectsActualReadFailures() async throws {
        let source = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "Managers/node-manager")
        for effectiveFailure in [true, false] {
            let fixture = try SourceNodeManagerFixture(managerSource: source, nonNVM: true)
            let config = fixture.root.appending(path: ".npmrc")
            try Data("@company:registry=\n".utf8).write(to: config)
            let summary: NodeSummary = try await fixture.client.request("summary", managerDirectory: fixture.manager, environment: fixture.environment)
            let empty = try await fixture.client.scopeRegistryLayers("@company", summary: summary, managerDirectory: fixture.manager)
            XCTAssertEqual(empty.effective, "")
            XCTAssertEqual(empty.user, "")
            XCTAssertEqual(empty.project, "undefined")
            XCTAssertEqual(empty.global, "undefined")
            if effectiveFailure { try Data().write(to: fixture.root.appending(path: "fail-effective-scope")) }
            else {
                try fixture.tool("ruby", #"""
                #!/bin/bash
                case "${2:-}" in *"File.foreach(config_file)"*) /bin/mv "$3" "$3.removed" ;; esac
                exec /usr/bin/ruby "$@"
                """#)
            }
            let result = try await ProcessRunner().run(.init(executableURL: URL(filePath: "/bin/bash"),
                arguments: [fixture.manager.appending(path: "main.sh").path, "--json", "plan", "scope-registry-delete", "@company"],
                environment: fixture.environment, currentDirectoryURL: fixture.manager))
            let envelope = try JSONDecoder().decode(ManagerEnvelope<NodeActionPlanPayload>.self, from: result.standardOutput)
            XCTAssertNotEqual(result.terminationStatus, 0)
            XCTAssertFalse(envelope.ok)
            XCTAssertNil(envelope.data)
            XCTAssertEqual(envelope.error?.code, "registry-state-unavailable")
            try Data("@company:registry=\n".utf8).write(to: config)
            do {
                _ = try await fixture.client.scopeRegistryLayers("@company", summary: summary, managerDirectory: fixture.manager)
                XCTFail("An actual bundled query or file read failure must fail the Swift boundary")
            } catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "registry-state-unavailable") }
        }
    }
}
