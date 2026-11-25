import XCTest
@testable import Cellar

@MainActor
final class ToolsDirectOperationTests: XCTestCase {
    func testShellRefreshRetainsLastSnapshotOnFailureAndClearsFailureAfterRecovery() async throws {
        let fixture = try ToolsDirectFixture()
        defer { fixture.remove() }
        fixture.model.selectedDestination = .settings
        let adapter = fixture.root.appending(path: "Cellar/Managers/\(ManagerSnapshotInstaller.snapshotVersion)/zsh-manager/app-json.sh")
        let successScript = #"""
        #!/bin/bash
        printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"snapshot","data":{"zshVersion":"first","ohMyZshInstalled":false,"ohMyZshPath":"","zshrcPath":"/fixture/.zshrc","zshrcExists":true,"currentTheme":"","activePlugins":[],"installedCustomPlugins":[],"availableThemes":[],"defaultPluginNames":[],"runtimeDirectory":""}}'
        """#
        await fixture.model.refresh()
        XCTAssertTrue(fixture.model.shellRefreshFailed, "A first read failure must be distinguishable from not checked")
        XCTAssertNil(fixture.model.shell)
        try Data(successScript.utf8).write(to: adapter)
        await fixture.model.refresh()
        XCTAssertFalse(fixture.model.shellRefreshFailed)
        XCTAssertEqual(fixture.model.shell?.zshVersion, "first")
        try Data("#!/bin/bash\nexit 1\n".utf8).write(to: adapter)
        await fixture.model.refresh()
        XCTAssertTrue(fixture.model.shellRefreshFailed, "A retained snapshot must not look freshly read")
        XCTAssertEqual(fixture.model.shell?.zshVersion, "first")
        try Data(successScript.replacingOccurrences(of: "first", with: "recovered").utf8).write(to: adapter)
        await fixture.model.refresh()
        XCTAssertFalse(fixture.model.shellRefreshFailed)
        XCTAssertEqual(fixture.model.shell?.zshVersion, "recovered")
    }

    func testCacheVerificationSurvivesUnrelatedRegistryPreparationAndDismissal() async throws {
        let fixture = try ToolsDirectFixture()
        defer { fixture.remove() }
        try Data("verify".utf8).write(to: fixture.root.appending(path: "mode"))
        fixture.model.node = try await fixture.node.loadSnapshot(managerDirectory: fixture.root.appending(path: "node-manager"))
        await fixture.model.performDirectNodeAction(NodeMaintenanceAction.verify.request)
        let result = try XCTUnwrap(fixture.model.nodeActionResult)
        XCTAssertEqual(result.operation.batchItemStatus, .succeeded)
        await fixture.model.prepareNodeAction(.init(action: .setRegistry, subject: "https://registry.example.test/"))
        XCTAssertNotNil(fixture.model.nodePlan)
        fixture.model.dismissNodePlan()
        guard case .completed(let retained) = fixture.model.currentNodeCacheVerification else { return XCTFail("Verification result must survive unrelated planning") }
        XCTAssertEqual(retained.plan.id, result.plan.id)
        fixture.model.dismissNodeFeedback()
        guard case .completed = fixture.model.currentNodeCacheVerification else { return XCTFail("Closing generic feedback must retain the check result") }
        let original = try XCTUnwrap(fixture.model.node)
        let otherCache = NodeConfiguration(registry: original.configuration.registry, cache: "/other/cache", prefix: "/fixture",
                                           userRegistry: "", projectRegistry: "", globalRegistry: "")
        fixture.model.node = NodeSnapshot(summary: original.summary, configuration: otherCache, packages: [], installations: [],
                                          managerStatus: nil, logs: [], outdatedError: nil, maintenanceError: nil)
        XCTAssertNil(fixture.model.currentNodeCacheVerification, "A different cache has not been checked")
        let otherNode = NodeSummary(nodePath: "/other/node", npmPath: original.summary.npmPath, nodeVersion: original.summary.nodeVersion,
                                    npmVersion: original.summary.npmVersion, nvmLoaded: false, globalPrefix: "/fixture",
                                    globalRoot: "/fixture/lib", registry: original.summary.registry)
        fixture.model.node = NodeSnapshot(summary: otherNode, configuration: original.configuration, packages: [], installations: [],
                                          managerStatus: nil, logs: [], outdatedError: nil, maintenanceError: nil)
        XCTAssertNil(fixture.model.currentNodeCacheVerification, "A different Node environment has not been checked")
        fixture.model.node = nil
        XCTAssertNil(fixture.model.currentNodeCacheVerification)
        fixture.model.node = original
        guard case .completed = fixture.model.currentNodeCacheVerification else { return XCTFail("The original target retains its result") }
    }

    func testFailedVerificationSurvivesUnrelatedPlanningAndReplacesPriorSuccess() async throws {
        let fixture = try ToolsDirectFixture()
        defer { fixture.remove() }
        fixture.model.node = try await fixture.node.loadSnapshot(managerDirectory: fixture.root.appending(path: "node-manager"))
        try Data("verify".utf8).write(to: fixture.root.appending(path: "mode"))
        await fixture.model.performDirectNodeAction(NodeMaintenanceAction.verify.request)
        guard case .completed = fixture.model.currentNodeCacheVerification else { return XCTFail("Expected initial success") }
        try Data("fail".utf8).write(to: fixture.root.appending(path: "mode"))
        await fixture.model.performDirectNodeAction(NodeMaintenanceAction.verify.request)
        await fixture.model.prepareNodeAction(.init(action: .setRegistry, subject: "https://registry.example.test/"))
        fixture.model.dismissNodePlan()
        guard case .failed = fixture.model.currentNodeCacheVerification else { return XCTFail("A failed recheck must replace the previous result") }
    }

    func testSettingsRefreshRechecksNVMWithoutHomeOrRuntimePage() async throws {
        let fixture = try ToolsDirectFixture()
        defer { fixture.remove() }
        fixture.model.selectedDestination = .settings
        let nvm = fixture.root.appending(path: ".nvm/nvm.sh")
        try FileManager.default.createDirectory(at: nvm.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: nvm)
        await fixture.model.refresh()
        XCTAssertEqual(fixture.model.nvmInstalled, true)
        try FileManager.default.removeItem(at: nvm)
        await fixture.model.refresh()
        XCTAssertEqual(fixture.model.nvmInstalled, false)
        try Data().write(to: nvm)
        await fixture.model.refresh()
        XCTAssertEqual(fixture.model.nvmInstalled, true)
    }

    func testNodeConfirmationsBelongToTheirConfigurationOrMaintenanceSurface() throws {
        let model = AppModel.live()
        let payload = try JSONDecoder().decode(NodeActionPlanPayload.self, from: Data(#"{"action":"cleanup","executeSupported":true,"executable":true}"#.utf8))
        let cases: [(NodeActionRequest, ProviderTaskSurface?)] = [
            (.init(action: .setRegistry, subject: "https://registry.example.test"), .npmSources),
            (.init(action: .setDefaultNode, subject: "v22.0.0"), .tools),
            (NodeMaintenanceAction.verify.request, nil),
        ] + NodeMaintenanceAction.allCases.filter { $0 != .verify }.map { ($0.request, .maintenance) }
        for (request, expectedSurface) in cases {
            let plan = NodeActionPlan(id: UUID(), request: request, payload: payload, generatedAt: Date())
            model.nodePlan = plan
            for surface in [ProviderTaskSurface.tools, .homebrewSources, .npmSources, .terminal, .maintenance] {
                let binding = ProviderTaskPresentation(model: model, surface: surface).nodeConfirmation
                XCTAssertEqual(binding.wrappedValue?.id, surface == expectedSurface ? plan.id : nil, request.subject)
            }
        }
    }

    func testOldMaintenanceSheetDismissalCannotClearNewCleanupPlan() throws {
        let model = AppModel.live()
        let payload = try JSONDecoder().decode(NodeActionPlanPayload.self, from: Data(#"{"action":"cleanup","executeSupported":true,"executable":true}"#.utf8))
        let old = NodeActionPlan(id: UUID(), request: NodeMaintenanceAction.npmCache.request, payload: payload, generatedAt: Date())
        model.nodePlan = old
        let binding = ProviderTaskPresentation(model: model, surface: .maintenance).nodeConfirmation
        XCTAssertEqual(binding.wrappedValue?.id, old.id)
        let newer = NodeActionPlan(id: UUID(), request: NodeMaintenanceAction.oldNode.request, payload: payload, generatedAt: Date())
        model.nodePlan = newer
        binding.wrappedValue = nil
        XCTAssertEqual(model.nodePlan?.id, newer.id)
    }

    func testFailedOrCancelledDirectPreparationCannotConsumePendingRegistryConfirmation() async throws {
        let requests = [NodeActionRequest(action: .installNode, subject: "v24.0.0"), .init(action: .useNode, subject: "v22.0.0"), NodeMaintenanceAction.verify.request]
        for cancelled in [false, true] {
            for request in requests {
                let fixture = try ToolsDirectFixture()
                defer { fixture.remove() }
                fixture.model.node = try await fixture.node.loadSnapshot(managerDirectory: fixture.root.appending(path: "node-manager"))
                let pending = try await fixture.node.plan(.init(action: .setRegistry, subject: "https://registry.example.test/"), managerDirectory: fixture.root.appending(path: "node-manager"))
                fixture.model.nodePlan = pending
                try Data((cancelled ? "wait" : "fail").utf8).write(to: fixture.root.appending(path: "mode"))
                let action = Task { await fixture.model.performDirectNodeAction(request) }
                if cancelled {
                    try await fixture.waitForRead()
                    if request == NodeMaintenanceAction.verify.request {
                        guard case .running = fixture.model.currentNodeCacheVerification else { return XCTFail("The model must own in-flight verification") }
                    }
                    action.cancel()
                }
                await action.value
                XCTAssertEqual(fixture.model.nodePlan?.id, pending.id)
                XCTAssertFalse(try fixture.calls().contains("execute|1"))
                if request == NodeMaintenanceAction.verify.request {
                    guard case .failed = fixture.model.currentNodeCacheVerification else { return XCTFail("Preparation failure must be retained") }
                }
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

    func testRefreshUpdatesCatalogOnlyFromHomebrewSourcesAndStillRefreshesAfterFailure() async throws {
        let cases: [(AppDestination, ToolsCategory)] = [
            (.home, .homebrewSources), (.tools, .homebrewSources), (.tools, .npmSources),
            (.tools, .terminal), (.tools, .runtime),
        ]
        for (destination, category) in cases {
            let fixture = try ToolsDirectFixture()
            defer { fixture.remove() }
            fixture.model.homebrew = .init(executablePath: fixture.root.appending(path: "brew").path, version: "fixture", managerAvailable: true, snapshot: nil)
            fixture.model.selectedDestination = destination
            fixture.model.selectedToolsCategory = category
            await fixture.model.performShellAction(.refresh)
            XCTAssertEqual(try fixture.calls().contains("update|brew"), destination == .tools && category == .homebrewSources)
            XCTAssertNotNil(fixture.model.refreshedAt)
            XCTAssertFalse(fixture.model.operationStore.hasActiveOperations)
        }
    }

    func testOldTapSheetDismissalCannotClearNewMetadataPlan() throws {
        let fixture = try ToolsDirectFixture()
        defer { fixture.remove() }
        let old = Self.tapPlan()
        fixture.model.homebrewPlan = old
        let binding = ProviderTaskPresentation(model: fixture.model, surface: .homebrewSources).homebrewConfirmation
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
        let nodeBinding = ProviderTaskPresentation(model: fixture.model, surface: .npmSources).nodeConfirmation
        let newer = NodeActionPlan(id: UUID(), request: old.request, payload: payload, generatedAt: Date())
        fixture.model.nodePlan = newer
        nodeBinding.wrappedValue = nil
        XCTAssertEqual(fixture.model.nodePlan?.id, newer.id)
        let shellPayload = try JSONDecoder().decode(ShellActionPlanPayload.self, from: Data(#"{"action":"tidy","subject":"zsh-files","targetPath":"/fixture","requiresConfirmation":true,"executable":true,"blockedReason":"","planToken":"fixture","generatedAt":0}"#.utf8))
        let oldShell = ShellActionPlan(id: UUID(), request: .init(action: .tidy, subject: "zsh-files"), payload: shellPayload, generatedAt: Date())
        fixture.model.shellPlan = oldShell
        let shellBinding = ProviderTaskPresentation(model: fixture.model, surface: .terminal).shellConfirmation
        XCTAssertEqual(shellBinding.wrappedValue?.id, oldShell.id)
        XCTAssertNil(ProviderTaskPresentation(model: fixture.model, surface: .tools).shellConfirmation.wrappedValue)
        XCTAssertNil(ProviderTaskPresentation(model: fixture.model, surface: .homebrewSources).shellConfirmation.wrappedValue)
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
        if [ "$2" = plan ] && [ "$3" != registry-set ] && [ "$(/bin/cat "$HOME/mode")" != verify ]; then
          /usr/bin/touch "$HOME/started"
          if [ "$(/bin/cat "$HOME/mode")" = wait ]; then /bin/sleep 30; fi
          printf '%s\n' '{"ok":false,"schemaVersion":1,"command":"plan","error":{"code":"fixture-failed"}}'
          exit 1
        fi
        case "$2" in
          summary) printf '{"ok":true,"schemaVersion":1,"command":"summary","data":{"nodePath":"%s/.nvm/versions/node/v22.0.0/bin/node","npmPath":"%s/.nvm/versions/node/v22.0.0/bin/npm","nodeVersion":"v22.0.0","npmVersion":"10.0.0","nvmLoaded":false,"globalPrefix":"%s/prefix","globalRoot":"%s/prefix/lib","registry":"https://registry.example.test/"}}\n' "$HOME" "$HOME" "$HOME" "$HOME" ;;
          packages) printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"packages","data":{"dependencies":{}}}' ;;
          config) printf '{"ok":true,"schemaVersion":1,"command":"config","data":{"registry":"https://registry.example.test/","cache":"%s/.npm","prefix":"%s/prefix","userRegistry":"","projectRegistry":"","globalRegistry":""}}\n' "$HOME" "$HOME" ;;
          logs) printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"logs","data":[]}' ;;
          outdated) printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"outdated","data":{}}' ;;
          plan) printf '{"ok":true,"schemaVersion":1,"command":"plan","data":{"action":"%s","effectiveRegistry":"https://registry.example.test/","executeSupported":true,"executable":true}}\n' "$3" ;;
          execute) printf '{"ok":true,"schemaVersion":1,"command":"execute","data":{"operationId":"fixture","action":"%s","subject":"%s","exitCode":0,"status":"ok","logFile":""}}\n' "$3" "$4" ;;
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
        // Full refresh must also use fake installed Managers and a fake controlled toolchain.
        let runtime = root.appending(path: "Cellar/Managers/\(ManagerSnapshotInstaller.snapshotVersion)")
        let bin = root.appending(path: ".nvm/versions/node/v22.0.0/bin")
        for directory in [runtime.appending(path: "node-manager"), runtime.appending(path: "homebrew-manager"),
                          runtime.appending(path: "zsh-manager"), bin, root.appending(path: ".nvm/alias")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.copyItem(at: root.appending(path: "main.sh"), to: runtime.appending(path: "node-manager/main.sh"))
        for file in [runtime.appending(path: "homebrew-manager/main.sh"), runtime.appending(path: "zsh-manager/omz-manager.sh"),
                     runtime.appending(path: "zsh-manager/app-json.sh"), bin.appending(path: "node"), bin.appending(path: "npm")] {
            try Data("#!/bin/bash\nexit 1\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        try Data("#!/bin/sh\ncase \"$*\" in \"config get userconfig\") printf '%s/.npmrc\\n' \"$HOME\" ;; prefix) printf '%s/prefix\\n' \"$HOME\" ;; \"config get cache\") printf '%s/.npm\\n' \"$HOME\" ;; *) printf '%s/global/npmrc\\n' \"$HOME\" ;; esac\n".utf8).write(to: bin.appending(path: "npm"))
        try FileManager.default.copyItem(at: brew, to: bin.appending(path: "brew"))
        try Data("v22.0.0".utf8).write(to: root.appending(path: ".nvm/alias/default"))
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
