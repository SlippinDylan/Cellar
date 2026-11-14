import Darwin
import XCTest
@testable import Cellar

final class NodeConfigurationSafetyTests: XCTestCase {
    func testProjectConfirmationKeepsOriginalExpiryAndFailedVerificationIsUnknown() async throws {
        for expired in [true, false] {
            let fixture = try NodeConfigurationFixture()
            defer { fixture.remove() }
            let project = fixture.root.appending(path: "project")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let prepared = try await fixture.client.plan(.init(action: .writeProjectNVMRC, subject: project.path, value: "v24.0.0"), managerDirectory: fixture.root)
            if expired {
                let plan = NodeActionPlan(id: prepared.id, request: prepared.request, payload: prepared.payload, generatedAt: Date().addingTimeInterval(-301))
                do { _ = try await fixture.client.execute(plan, managerDirectory: fixture.root); XCTFail("Directory revalidation must not renew confirmation") }
                catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "plan-expired") }
                XCTAssertFalse(try fixture.calls().contains("execute|1|1"))
            } else {
                try Data().write(to: fixture.root.appending(path: "wrong-project-version"))
                let result = try await fixture.client.execute(prepared, managerDirectory: fixture.root)
                XCTAssertEqual(result.batchItemStatus, .unknown)
                XCTAssertEqual(result.activityReason, .stateUnavailable)
                XCTAssertEqual(result.detail, "project-verification-unavailable")
            }
        }
    }

    func testProjectReplacementDuringFinalPlanningIsRejectedBeforeWriteGate() async throws {
        let fixture = try NodeConfigurationFixture()
        defer { fixture.remove() }
        let project = fixture.root.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let plan = try await fixture.client.plan(.init(action: .writeProjectNVMRC, subject: project.path, value: "v24.0.0"), managerDirectory: fixture.root)
        try Data().write(to: fixture.root.appending(path: "replace-during-plan"))
        do { _ = try await fixture.client.execute(plan, managerDirectory: fixture.root); XCTFail("Final planning must not replace the selected directory") }
        catch { XCTAssertEqual(ActivityItemReason(error: error), .stateChanged) }
        XCTAssertFalse(try fixture.calls().contains("execute|1|1"))
        for name in ["project", "project-during-plan"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appending(path: "\(name)/.nvmrc").path))
        }
    }

    func testProjectFinalSymlinksAndDotTraversalRefuseBeforePlanning() async throws {
        let fixture = try NodeConfigurationFixture()
        defer { fixture.remove() }
        let actual = fixture.root.appending(path: "actual")
        let link = fixture.root.appending(path: "selected")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
        for path in [link.path, link.path + "/", actual.path + "/../actual"] {
            do { _ = try await fixture.client.plan(.init(action: .writeProjectNVMRC, subject: path, value: "v24.0.0"), managerDirectory: fixture.root); XCTFail("Unsafe selected path must refuse") }
            catch { XCTAssertEqual(ActivityItemReason(error: error), .stateChanged) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appending(path: "calls.log").path))
    }

    func testEmptyProjectDirectoryReplacementCannotOpenWriteGate() async throws {
        for replacement in ["project-symlink", "ancestor-symlink", "recreated-directory"] {
            let fixture = try NodeConfigurationFixture()
            defer { fixture.remove() }
            let parent = fixture.root.appending(path: "selected")
            let project = parent.appending(path: "project")
            let otherParent = fixture.root.appending(path: "other")
            let other = otherParent.appending(path: "project")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            let plan = try await fixture.client.plan(.init(action: .writeProjectNVMRC, subject: project.path, value: "v24.0.0"), managerDirectory: fixture.root)
            let moved = fixture.root.appending(path: "original")
            if replacement == "ancestor-symlink" {
                try FileManager.default.moveItem(at: parent, to: moved)
                try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: otherParent)
            } else {
                try FileManager.default.moveItem(at: project, to: moved)
                if replacement == "project-symlink" { try FileManager.default.createSymbolicLink(at: project, withDestinationURL: other) }
                else { try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false) }
            }
            do { _ = try await fixture.client.execute(plan, managerDirectory: fixture.root); XCTFail("Directory identity changed: \(replacement)") }
            catch { XCTAssertEqual(ActivityItemReason(error: error), .stateChanged) }
            XCTAssertFalse(try fixture.calls().contains("execute|1|1"))
            for directory in [project, other, moved, moved.appending(path: "project")] {
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: ".nvmrc").path), replacement)
            }
        }
    }

    func testEmptyProjectUsesCapturedCanonicalDirectoryAndVerifiesWrittenVersion() async throws {
        let fixture = try NodeConfigurationFixture()
        defer { fixture.remove() }
        let actual = fixture.root.appending(path: "actual/project")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let alias = fixture.root.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual.deletingLastPathComponent())
        let selected = alias.appending(path: "project")
        let plan = try await fixture.client.plan(.init(action: .writeProjectNVMRC, subject: selected.path, value: "v24.0.0"), managerDirectory: fixture.root)
        XCTAssertEqual(plan.request.subject, selected.path)
        let result = try await fixture.client.execute(plan, managerDirectory: fixture.root)
        XCTAssertEqual(result.batchItemStatus, .succeeded)
        XCTAssertEqual(try String(contentsOf: actual.appending(path: ".nvmrc"), encoding: .utf8), "v24.0.0\n")
        let canonical = try XCTUnwrap(realpath(actual.path, nil))
        defer { free(canonical) }
        XCTAssertEqual(try String(contentsOf: fixture.root.appending(path: "executed-project"), encoding: .utf8), String(cString: canonical))
        XCTAssertEqual(try fixture.calls().split(separator: "\n").filter { $0.hasPrefix("execute|1|1") }.count, 1)
        do { _ = try await fixture.client.execute(plan, managerDirectory: fixture.root); XCTFail("Confirmation must be consumed once") }
        catch { XCTAssertEqual(ActivityItemReason(error: error), .stateChanged) }
    }

    func testProjectPostWriteDirectoryDriftCannotReportSuccess() async throws {
        let fixture = try NodeConfigurationFixture()
        defer { fixture.remove() }
        let project = fixture.root.appending(path: "project")
        let other = fixture.root.appending(path: "other")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let plan = try await fixture.client.plan(.init(action: .writeProjectNVMRC, subject: project.path, value: "v24.0.0"), managerDirectory: fixture.root)
        try Data().write(to: fixture.root.appending(path: "redirect-after-write"))
        let result = try await fixture.client.execute(plan, managerDirectory: fixture.root)
        XCTAssertEqual(result.batchItemStatus, .unknown)
        XCTAssertEqual(result.activityReason, .stateChanged)
        XCTAssertEqual(try String(contentsOf: fixture.root.appending(path: "project-after-write/.nvmrc"), encoding: .utf8), "v24.0.0\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appending(path: ".nvmrc").path))
    }

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
        for request in [NodeActionRequest(action: .setScopeRegistry, subject: "@company", value: "http://localhost/"),
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
        let bin = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["node", "npm"] {
            let tool = bin.appending(path: name)
            try Data("#!/bin/sh\ncase \"$*\" in \"config get userconfig\") printf '%s/.npmrc\\n' \"$HOME\" ;; prefix) printf '%s/prefix\\n' \"$HOME\" ;; *) printf '%s/prefix/etc/npmrc\\n' \"$HOME\" ;; esac\n".utf8).write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
        let script = #"""
        #!/bin/bash
        printf '%s|%s|%s|%s\n' "$2" "$NODE_MANAGER_ALLOW_JSON_EXECUTE" "${NODE_MANAGER_ALLOW_PROJECT_WRITE:-0}" "$3" >> "$HOME/calls.log"
        case "$2" in
          summary)
            printf '{"ok":true,"schemaVersion":1,"command":"summary","data":{"nodePath":"%s/bin/node","npmPath":"%s/bin/npm","nodeVersion":"v24.0.0","npmVersion":"11.0.0","nvmLoaded":false,"globalPrefix":"%s/prefix","globalRoot":"%s/prefix/lib/node_modules","registry":"https://registry.example.test/"}}\n' "$HOME" "$HOME" "$HOME" "$HOME" ;;
          plan)
            if [ "$3" = project-nvmrc ] && [ -f "$HOME/replace-during-plan" ]; then
              /bin/mv "$4" "$HOME/project-during-plan"
              /bin/mkdir "$4"
            fi
            printf '{"ok":true,"schemaVersion":1,"command":"plan","data":{"action":"%s","effectiveRegistry":"http://registry.example.test/","userRegistry":"","projectRegistry":"","globalRegistry":"","executeSupported":true,"executable":true}}\n' "$3"
            ;;
          execute)
            if [ "$3" = project-nvmrc ]; then
              printf '%s' "$4" > "$HOME/executed-project"
              printf '%s\n' "$5" > "$4/.nvmrc"
              [ ! -f "$HOME/wrong-project-version" ] || printf 'v25.0.0\n' > "$4/.nvmrc"
              if [ -f "$HOME/redirect-after-write" ]; then
                /bin/mv "$4" "$HOME/project-after-write"
                /bin/ln -s "$HOME/other" "$4"
              fi
            fi
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
