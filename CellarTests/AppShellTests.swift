import AppKit
import XCTest
@testable import Cellar

@MainActor
final class AppShellTests: XCTestCase {
    func testActivityIntentPresentsOneMainWindowFromMainClosedAndSettingsOnlyStates() {
        for (hasMain, hasSettings) in [(true, false), (false, false), (false, true)] {
            let model = AppModel.live()
            var mainIsOpen = hasMain
            var created = 0
            var presentations = 0
            let present: (String, MainWindowIdentity) -> Void = { id, identity in
                XCTAssertEqual(id, AppScene.mainWindowID)
                XCTAssertEqual(identity, .main)
                XCTAssertEqual(model.selectedDestination, .activity)
                if !mainIsOpen { mainIsOpen = true; created += 1 }
                presentations += 1
            }
            model.showActivity(presentMainWindow: present)
            model.showActivity(presentMainWindow: present)
            XCTAssertTrue(mainIsOpen, "Settings open: \(hasSettings)")
            XCTAssertEqual(created, hasMain ? 0 : 1)
            XCTAssertEqual(presentations, 2)
            XCTAssertFalse(model.operationStore.hasActiveOperations)
        }
    }

    func testDestinationContractAndDefaultSelection() {
        XCTAssertEqual(AppDestination.primaryDestinations, [.home, .library, .discover, .updates, .tools])
        XCTAssertEqual(AppDestination.allCases, AppDestination.primaryDestinations + [.activity])
        XCTAssertEqual(AppModel.live().selectedDestination, .home)
        XCTAssertEqual(SettingsPane.allCases, [.general, .sources, .terminal, .about])
    }

    func testHostedStartupDoesNotRefreshOrCreateActivity() async {
        let model = AppModel.live()
        await model.refreshOnLaunch()
        XCTAssertNil(model.refreshedAt)
        XCTAssertNil(model.managers)
        XCTAssertNil(model.activityStore)
        XCTAssertTrue(model.activities.isEmpty)
        XCTAssertFalse(model.operationStore.hasActiveOperations)
    }

    func testStartupPolicySkipsTestsAndAlreadyLoadedState() {
        XCTAssertFalse(AppRuntime.shouldRefreshOnLaunch(refreshedAt: nil, environment: ["XCTestConfigurationFilePath": "fixture"]))
        XCTAssertFalse(AppRuntime.shouldRefreshOnLaunch(refreshedAt: Date(), environment: [:]))
        XCTAssertTrue(AppRuntime.shouldRefreshOnLaunch(refreshedAt: nil, environment: [:]))
    }

    func testSharedIntentNavigatesAndBusyRefreshDoesNotStartIO() async {
        let model = AppModel.live()
        await model.performShellAction(.show(.activity))
        XCTAssertEqual(model.selectedDestination, .activity)
        model.isNodeWorking = true
        await model.performShellAction(.refresh)
        XCTAssertNil(model.managers)
        XCTAssertTrue(model.activities.isEmpty)
        XCTAssertFalse(model.operationStore.hasActiveOperations)
    }

    func testSharedCancelIntentCancelsTheRegisteredTask() async throws {
        let model = AppModel.live()
        let operationID = model.operationStore.begin()
        defer { model.operationStore.end(operationID) }
        let task = Task {
            try await model.operationStore.performCancellable(operationID: operationID) {
                try await Task.sleep(for: .seconds(30))
            }
        }
        while model.operationStore.activeTask == nil { await Task.yield() }
        await model.performShellAction(.cancel)
        XCTAssertEqual(model.operationStore.activeTask?.cancellationRequested, true)
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertNil(model.operationStore.activeTask)
    }

    func testSceneAndMenuUseNativeSettingsAndSharedIntents() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let scene = try String(contentsOf: root.appending(path: "CellarApp.swift"), encoding: .utf8)
        let shell = try String(contentsOf: root.appending(path: "Features/AppRootView.swift"), encoding: .utf8)
        let commands = try String(contentsOf: root.appending(path: "Features/AppCommands.swift"), encoding: .utf8)
        let settings = try String(contentsOf: root.appending(path: "Features/Settings/SettingsView.swift"), encoding: .utf8)
        let feedback = try String(contentsOf: root.appending(path: "Features/Tools/ProviderTaskPresentation.swift"), encoding: .utf8)
        XCTAssertTrue(scene.contains("WindowGroup(id: AppScene.mainWindowID, for: MainWindowIdentity.self)"))
        XCTAssertTrue(scene.contains("defaultValue:"))
        XCTAssertTrue(feedback.contains("model.showActivity { openWindow(id: $0, value: $1) }"))
        XCTAssertTrue(commands.contains("model.showActivity { openWindow(id: $0, value: $1) }"))
        XCTAssertTrue(commands.contains("if destination == .activity { model.showActivity"))
        XCTAssertTrue(shell.contains("model.showActivity { openWindow(id: $0, value: $1) }"))
        XCTAssertTrue(scene.contains("Settings {"))
        XCTAssertTrue(scene.contains("SidebarCommands()"))
        XCTAssertFalse(shell.contains("SettingsView("))
        XCTAssertFalse(shell.contains("utilityRow"))
        XCTAssertTrue(shell.contains("performShellAction(.refresh)"))
        XCTAssertTrue(commands.contains("performShellAction(.refresh)"))
        XCTAssertTrue(commands.contains("performShellAction(.cancel)"))
        XCTAssertTrue(commands.contains(".keyboardShortcut(\"r\", modifiers: .command)"))
        XCTAssertTrue(settings.contains("@AppStorage(\"settings.pane\")"))
        XCTAssertTrue(settings.contains("store: defaults"))
        XCTAssertTrue(settings.contains("changeLanguage(pendingLanguage)"))
        XCTAssertTrue(settings.contains(".onReceive(relaunchController.$selectedLanguage)"))
    }
}
