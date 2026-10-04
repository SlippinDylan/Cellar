import AppKit
import XCTest
@testable import Cellar

@MainActor
final class LifecycleTests: XCTestCase {
    func testCoreRefreshHasOneCancellableOwnerUntilProviderIsReaped() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarRefreshTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appending(path: "Cellar/Managers/\(ManagerSnapshotInstaller.snapshotVersion)")
        let bin = root.appending(path: ".nvm/versions/node/v22.0.0/bin")
        for directory in [bin, root.appending(path: ".nvm/alias"), runtime.appending(path: "node-manager"), runtime.appending(path: "homebrew-manager"), runtime.appending(path: "zsh-manager")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("v22.0.0".utf8).write(to: root.appending(path: ".nvm/alias/default"))
        let script = "#!/bin/bash\nprintf '%s' $$ > '\(root.path)/provider-pid'\nexec /bin/sleep 60\n"
        for (file, contents) in [(runtime.appending(path: "node-manager/main.sh"), script),
                                 (runtime.appending(path: "homebrew-manager/main.sh"), "fixture"),
                                 (runtime.appending(path: "zsh-manager/omz-manager.sh"), "fixture"),
                                 (runtime.appending(path: "zsh-manager/app-json.sh"), "#!/bin/bash\nprintf '%s\\n' '{\"ok\":true,\"schemaVersion\":1,\"command\":\"snapshot\",\"data\":{\"zshVersion\":\"fixture\",\"ohMyZshInstalled\":false,\"ohMyZshPath\":\"\",\"zshrcPath\":\"\",\"zshrcExists\":false,\"currentTheme\":\"\",\"activePlugins\":[],\"installedCustomPlugins\":[],\"availableThemes\":[],\"defaultPluginNames\":[],\"runtimeDirectory\":\"\"}}'\n"),
                                 (bin.appending(path: "node"), "#!/bin/bash\nexit 1\n"),
                                 (bin.appending(path: "brew"), "#!/bin/bash\nexit 1\n")] {
            try Data(contents.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let runner = ProcessRunner()
        let resolver = NodeEnvironmentResolver(homeDirectory: root)
        let service = SystemProbeService(runner: runner, installer: .init(applicationSupportDirectory: root),
            nodeClient: .init(runner: runner, environmentResolver: resolver),
            shellClient: .init(runner: runner, environmentResolver: .init(homeDirectory: root, temporaryDirectory: root)), environmentResolver: resolver)
        let store = OperationStore()
        let activity = ActivityStore(applicationSupportRoot: root)
        let model = AppModel(service: service, operationStore: store, activityStore: activity)
        let task = Task { await model.refreshOnLaunch(environment: [:]) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (!FileManager.default.fileExists(atPath: root.appending(path: "provider-pid").path) || model.shell == nil), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(store.hasActiveOperations)
        XCTAssertNotNil(store.activeTask)
        XCTAssertEqual(AppTerminationPolicy.reply(hasActiveOperations: store.hasActiveOperations), .terminateCancel)
        await model.refresh()
        XCTAssertEqual(store.activeOperationCount, 1)
        await model.performShellAction(.cancel)
        if store.activeTask == nil { task.cancel() }
        await task.value
        XCTAssertFalse(store.hasActiveOperations)
        XCTAssertNil(store.activeTask)
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(activity.summaries.first?.status, .cancelled)
        XCTAssertFalse(model.nodeRefreshFailed)
        XCTAssertEqual(model.shell?.zshVersion, "fixture")
        XCTAssertNil(model.refreshedAt, "Cancelled launch refresh must not start automatic online enrichment")
        let pid = try XCTUnwrap(Int32(String(contentsOf: root.appending(path: "provider-pid"), encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), -1)
    }

    func testTerminationIsAllowedWithoutActiveOperation() {
        XCTAssertEqual(
            AppTerminationPolicy.reply(hasActiveOperations: false),
            .terminateNow
        )
    }

    func testTerminationIsRefusedDuringActiveOperation() {
        XCTAssertEqual(
            AppTerminationPolicy.reply(hasActiveOperations: true),
            .terminateCancel
        )
    }

    func testAppDelegateReadsTheSharedOperationState() {
        let store = OperationStore.shared
        XCTAssertFalse(store.hasActiveOperations)
        let identifier = store.begin()

        XCTAssertEqual(
            AppDelegate().applicationShouldTerminate(NSApplication.shared),
            .terminateCancel
        )

        store.end(identifier)
        XCTAssertEqual(
            AppDelegate().applicationShouldTerminate(NSApplication.shared),
            .terminateNow
        )
    }

    func testBusyStateCoversEveryModule() {
        let model = AppModel.live()

        XCTAssertFalse(model.isBusy)
        model.isHomebrewWorking = true
        XCTAssertTrue(model.isBusy)
        model.isHomebrewWorking = false
        model.isNodeWorking = true
        XCTAssertTrue(model.isBusy)
        model.isNodeWorking = false
        model.isShellWorking = true
        XCTAssertTrue(model.isBusy)
    }

    func testHostedLiveModelDoesNotLoadOrCreatePersistentActivity() {
        XCTAssertNotNil(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"])
        XCTAssertNil(AppModel.live().activityStore)
    }

    func testHomebrewExecutionWaitsForAnotherModule() async {
        let model = AppModel.live()
        let plan = HomebrewActionPlan(
            id: UUID(),
            action: .update,
            targets: [],
            tapName: nil,
            dependencies: [],
            dependents: [],
            artifacts: [],
            residualPaths: [],
            associatedPackages: [],
            generatedAt: Date(),
            stateFingerprint: nil
        )
        model.homebrewPlan = plan
        model.isNodeWorking = true

        await model.executeHomebrewPlan()

        XCTAssertEqual(model.homebrewPlan?.id, plan.id)
        XCTAssertFalse(model.isHomebrewWorking)
    }
}
