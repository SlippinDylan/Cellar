import XCTest
@testable import Cellar

final class ToolsConfigurationTests: XCTestCase {
    func testMaintenanceRawErrorsAreOnlyAvailableInExplicitSessionDiagnostics() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "Features/Tools/NodeMaintenanceView.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("DiagnosticText.sanitized(error)"))
        XCTAssertTrue(source.contains("ActivityDiagnosticsView"))
    }

    func testProjectReadsHaveViewOwnershipLoadingFeedbackAndRejectLateResults() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "Features/Tools/ProjectToolsView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(".task(id: readRequest)"))
        XCTAssertTrue(source.contains("isReading"))
        XCTAssertFalse(source.contains("Task { await readProject"))
        XCTAssertTrue(source.contains("!Task.isCancelled"))
    }

    func testTapConfirmationBoundsAssociatedItemsAndKeepsActionsOutsideScrollingContent() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "Features/Settings/TapTaskConfirmation.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("ScrollView"))
        XCTAssertTrue(source.contains("LazyVStack"))
        XCTAssertTrue(source.contains(".frame(maxHeight: 240)"))
        XCTAssertTrue(source.contains(".keyboardShortcut(.cancelAction)"))
        XCTAssertFalse(source.contains(".keyboardShortcut(.defaultAction)"))
        if source.contains(".frame(maxHeight: 240)") {
            let scrollEnd = try XCTUnwrap(source.range(of: ".frame(maxHeight: 240)"))
            let cancel = try XCTUnwrap(source.range(of: "Button(\"Cancel\""))
            XCTAssertTrue(scrollEnd.lowerBound < cancel.lowerBound)
        }
    }

    func testTerminalConfirmationsBoundLongPluginListsAndPathsWithoutScrollingActions() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Features/Settings/TerminalSettingsView.swift", "Features/Settings/ShellTaskConfirmation.swift"] {
            let fileSource = try String(contentsOf: root.appending(path: file), encoding: .utf8)
            let source: String
            if file.hasSuffix("TerminalSettingsView.swift") {
                let confirmation = try XCTUnwrap(fileSource.range(of: "private struct TerminalApplyConfirmation"))
                source = String(fileSource[confirmation.lowerBound...])
            } else {
                source = fileSource
            }
            XCTAssertTrue(source.contains(".frame(maxHeight: 280)"), file)
            if let scrollEnd = source.range(of: ".frame(maxHeight: 280)"), let cancel = source.range(of: "Button(\"Cancel\"") {
                XCTAssertTrue(scrollEnd.lowerBound < cancel.lowerBound, file)
            }
            XCTAssertFalse(source.contains(".keyboardShortcut(.defaultAction)"), file)
        }
    }

    @MainActor
    func testRuntimeCatalogErrorsUseActionableMessagesInsteadOfProviderDumps() async {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarRuntimeErrors-\(UUID())")
        let runner = ProcessRunner()
        let resolver = NodeEnvironmentResolver(homeDirectory: root)
        let service = SystemProbeService(runner: runner, installer: ManagerSnapshotInstaller(applicationSupportDirectory: root), nodeClient: NodeManagerClient(runner: runner, environmentResolver: resolver),
                                         shellClient: ShellManagerClient(runner: runner, environmentResolver: .init(homeDirectory: root)), environmentResolver: resolver)
        let model = AppModel(service: service, operationStore: OperationStore())
        for (error, message) in [(URLError(.notConnectedToInternet) as Error, "Node versions could not be loaded while offline. Connect to the internet and try again."),
                                 (CatalogSourceError.invalidResponse as Error, "The official Node version list could not be verified. Try loading it again."),
                                 (URLError(.timedOut) as Error, "The official Node service could not be reached. Check the connection and try again."),
                                 (BridgeError.invalidOutput("secret raw dump") as Error, "The official Node version list is unavailable. Try again later."),
                                 (CancellationError() as Error, "Loading Node versions was cancelled. You can try again.")] {
            let runtime = RuntimeToolsModel(loadReleases: { throw error })
            await runtime.refresh(model: model)
            XCTAssertEqual(runtime.error.map { String(localized: $0.message) }, String(localized: String.LocalizationValue(message)))
        }
    }

    func testOfficialRuntimeCatalogIsSeparateFromRegistryAndBoundedToArm64() async throws {
        let payload = (0..<130).map { ["version": "v24.0.\($0)", "files": ["osx-arm64-tar"]] }
            + [["version": "v22.0.0", "files": ["osx-x64-tar"]], ["version": "latest", "files": ["osx-arm64-tar"]]]
        let transport = FakeCatalogTransport(body: try JSONSerialization.data(withJSONObject: payload))
        let client = OfficialNodeReleaseClient(http: CatalogHTTPClient(transport: transport))
        let releases = try await client.releases()
        XCTAssertEqual(releases.count, 100)
        XCTAssertFalse(releases.contains { $0.version == "latest" || $0.version == "v22.0.0" })
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url, CatalogWebsites.url(host: "nodejs.org", path: "/dist/index.json"))
        XCTAssertEqual(requests[0].allowedOrigins, ["https://nodejs.org"])
        XCTAssertEqual(requests[0].maximumBytes, 2 * 1_024 * 1_024)
    }

    @MainActor
    func testRuntimeReadIsExplicitAndHonorsSharedOperationSlot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarToolsStateTests-\(UUID())")
        let runner = ProcessRunner()
        let resolver = NodeEnvironmentResolver(homeDirectory: root)
        let store = OperationStore()
        let service = SystemProbeService(runner: runner, installer: ManagerSnapshotInstaller(applicationSupportDirectory: root),
                                         nodeClient: NodeManagerClient(runner: runner, environmentResolver: resolver),
                                         shellClient: ShellManagerClient(runner: runner, environmentResolver: ShellEnvironmentResolver(homeDirectory: root)),
                                         environmentResolver: resolver)
        let model = AppModel(service: service, operationStore: store)
        let counter = RuntimeReadCounter()
        let runtime = RuntimeToolsModel(loadReleases: { await counter.read() })
        let initial = await counter.count
        XCTAssertEqual(initial, 0)
        model.openRuntimeTools()
        XCTAssertEqual(model.selectedDestination, .tools)
        XCTAssertEqual(model.selectedToolsCategory, .runtime)
        for category in ToolsCategory.allCases { model.selectedToolsCategory = category; XCTAssertEqual(model.selectedToolsCategory, category) }
        let busy = store.begin()
        await runtime.refresh(model: model)
        let whileBusy = await counter.count
        XCTAssertEqual(whileBusy, 0)
        store.end(busy)
        await runtime.refresh(model: model)
        let afterAction = await counter.count
        XCTAssertEqual(afterAction, 1)
        XCTAssertFalse(store.hasActiveOperations)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testReachableTaskSurfacesDoNotPresentCommandsOrNVMRemoteInstall() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let files = ["Features/Tools/RuntimeToolsView.swift", "Features/Home/HomeView.swift", "Features/Tools/NodeMaintenanceView.swift", "Features/Tools/ProjectToolsView.swift",
                     "Features/Settings/HomebrewSourcesView.swift", "Features/Settings/NPMRegistrySettingsView.swift", "Features/Settings/TerminalSettingsView.swift"]
        for file in files {
            let source = try String(contentsOf: root.appending(path: file), encoding: .utf8)
            for forbidden in [".installNVM", "bash -c", "curl |", "sudo", "chsh", "Text(\"Generate Plan", "Text(\"Execute Plan", "command.arguments", "DEFAULT_PLUGIN_SPECS"] {
                XCTAssertFalse(source.contains(forbidden), "\(file): \(forbidden)")
            }
        }
        let rootView = try String(contentsOf: root.appending(path: "Features/AppRootView.swift"), encoding: .utf8)
        XCTAssertTrue(rootView.contains(".tools { ToolsView(model: model) }"))
        let app = try String(contentsOf: root.appending(path: "CellarApp.swift"), encoding: .utf8)
        XCTAssertTrue(rootView.contains("SettingsView(model: model"))
        XCTAssertFalse(app.contains("Settings {"))
    }

    func testDiagnosticsRedactsCredentialsAndSecrets() {
        let result = DiagnosticText.sanitized("https://user:secret@example.test/ token=secret Authorization: Bearer private cookie=session")
        XCTAssertFalse(result.contains("user:secret"))
        XCTAssertFalse(result.contains("token=secret"))
        XCTAssertFalse(result.contains("Bearer private"))
        XCTAssertFalse(result.contains("private"))
        XCTAssertFalse(result.contains("cookie=session"))
    }
    func testToolsCategoriesAndMaintenanceAllowlist() {
        XCTAssertEqual(ToolsCategory.allCases, [.terminal, .homebrewSources, .npmSources, .runtime])
        XCTAssertEqual(NodeMaintenanceAction.allCases.map(\.rawValue), ["npm-cache-verify", "npm-cache-clean", "node-gyp-cache", "orphan-bins", "nvm-old-versions", "logs"])
        XCTAssertFalse(NodeMaintenanceAction.allCases.map(\.rawValue).contains("cleanup"))
        XCTAssertEqual(NodeMaintenanceAction.allCases.filter { $0.category == .checks }, [.verify])
        XCTAssertEqual(NodeMaintenanceAction.allCases.filter { $0.category == .cleanup }, [.npmCache, .nodeGyp, .orphanBins, .oldNode, .logs])
        XCTAssertEqual(MaintenanceCategory.allCases, [.checks, .cleanup])
        XCTAssertEqual(SettingsCategory.allCases, [.general, .environment])
    }

    func testCustomPluginRequiresExactCredentialFreeGitHubRepository() {
        XCTAssertEqual(TerminalPluginSource.repository("https://github.com/owner/plugin.git")?.absoluteString, "https://github.com/owner/plugin")
        for value in ["http://github.com/o/r", "https://user@github.com/o/r", "https://github.com/o/r/tree/main", "https://github.com/o/r?token=x", "https://github.com/o/r#x", "https://github.com:443/o/r", "https://gitlab.com/o/r", "https://github.com/../r", "https://github.com/o/r%2fmore"] {
            XCTAssertNil(TerminalPluginSource.repository(value), value)
        }
    }

    func testRegistryKeepsUserHTTPAndRejectsCredentialsAndMalformedScopes() {
        XCTAssertEqual(SourceConfiguration.registryURL("http://registry.example.test/")?.scheme, "http")
        XCTAssertNil(SourceConfiguration.registryURL("https://user:secret@example.test/"))
        XCTAssertNil(SourceConfiguration.registryURL("https://example.test/#token"))
        XCTAssertTrue(SourceConfiguration.validScope("@company"))
        for scope in ["company", "@", "@company/name", "@Company", "@a b", "@../bad"] { XCTAssertFalse(SourceConfiguration.validScope(scope), scope) }
    }

    func testCurrentAndDefaultRuntimeCannotBeRemoved() {
        XCTAssertFalse(RuntimeProtection.canUninstall(.init(version: "v22.0.0", directory: "/fixture", isActive: true, isDefault: false)))
        XCTAssertFalse(RuntimeProtection.canUninstall(.init(version: "v22.0.0", directory: "/fixture", isActive: false, isDefault: true)))
        XCTAssertTrue(RuntimeProtection.canUninstall(.init(version: "v22.0.0", directory: "/fixture", isActive: false, isDefault: false)))
    }

    func testBlockedRuntimeAndProjectActionsHaveSpecificVisibleReasons() throws {
        for (reason, message) in [
            ("cannot-uninstall-current-node", LocalizedStringResource("The current Cellar Node version cannot be removed.")),
            ("cannot-uninstall-default-node", LocalizedStringResource("The nvm default Node version cannot be removed.")),
            ("project-nvmrc-not-regular-file", LocalizedStringResource("The project .nvmrc must be a regular file. Symbolic links are not changed."))
        ] {
            let data = try JSONSerialization.data(withJSONObject: ["action": "node-uninstall", "executable": false, "blockedReason": reason])
            let payload = try JSONDecoder().decode(NodeActionPlanPayload.self, from: data)
            let plan = NodeActionPlan(id: UUID(), request: .init(action: .uninstallNode, subject: "v22.0.0"), payload: payload, generatedAt: Date())
            XCTAssertFalse(plan.canExecute)
            XCTAssertEqual(String(localized: plan.blockingMessage), String(localized: message))
        }
    }
}

private actor RuntimeReadCounter {
    private(set) var count = 0
    func read() -> [OfficialNodeRelease] { count += 1; return [] }
}
