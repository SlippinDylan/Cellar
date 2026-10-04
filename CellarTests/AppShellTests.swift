import AppKit
import XCTest
@testable import Cellar

@MainActor
final class AppShellTests: XCTestCase {
    func testSettingsAndActivityIntentsPresentOneMainWindowFromOpenAndClosedStates() {
        for (destination, hasMain) in [(AppDestination.settings, true), (.settings, false), (.activity, true), (.activity, false)] {
            let model = AppModel.live()
            var mainIsOpen = hasMain
            var created = 0
            var presentations = 0
            let present: (String, MainWindowIdentity) -> Void = { id, identity in
                XCTAssertEqual(id, AppScene.mainWindowID)
                XCTAssertEqual(identity, .main)
                XCTAssertEqual(model.selectedDestination, destination)
                if !mainIsOpen { mainIsOpen = true; created += 1 }
                presentations += 1
            }
            model.showDestination(destination, presentMainWindow: present)
            model.showDestination(destination, presentMainWindow: present)
            XCTAssertTrue(mainIsOpen)
            XCTAssertEqual(created, hasMain ? 0 : 1)
            XCTAssertEqual(presentations, 2)
            XCTAssertFalse(model.operationStore.hasActiveOperations)
        }
    }

    func testDestinationContractAndDefaultSelection() {
        XCTAssertEqual(AppDestination.primaryDestinations, [.home, .library, .discover, .updates, .tools])
        XCTAssertEqual(AppDestination.bottomDestinations, [.settings, .activity])
        XCTAssertEqual(AppDestination.allCases.map(\.rawValue), ["home", "library", "discover", "updates", "tools", "settings", "activity"])
        XCTAssertEqual(AppModel.live().selectedDestination, .home)
        XCTAssertEqual(SettingsPane.allCases, [.general, .sources, .terminal, .about])
    }

    func testSidebarListsOnlyReceiveOwnedSelectionsAndMenuActionsStayFocused() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let shell = try String(contentsOf: root.appending(path: "Features/AppRootView.swift"), encoding: .utf8)
        XCTAssertTrue(shell.contains("selection: sidebarSelection(for: AppDestination.primaryDestinations)"))
        XCTAssertTrue(shell.contains("selection: sidebarSelection(for: AppDestination.bottomDestinations)"))
        XCTAssertTrue(shell.contains("destinations.contains(model.selectedDestination)"))
        let activity = try String(contentsOf: root.appending(path: "Features/Activity/ActivityView.swift"), encoding: .utf8)
        XCTAssertTrue(activity.contains(".onCopyCommand"))
        XCTAssertFalse(activity.contains(".keyboardShortcut(\"c\""))
    }

    func testOwnedSidebarBindingsRetainSharedNavigationAcrossEveryTransition() {
        let model = AppModel.live()
        let view = AppRootView(model: model, updateController: ApplicationUpdateController(updaterEnabled: false))
        let primary = view.sidebarSelection(for: AppDestination.primaryDestinations)
        let bottom = view.sidebarSelection(for: AppDestination.bottomDestinations)
        for destination in AppDestination.allCases {
            model.selectedDestination = destination
            XCTAssertEqual(primary.wrappedValue, AppDestination.primaryDestinations.contains(destination) ? destination : nil)
            XCTAssertEqual(bottom.wrappedValue, AppDestination.bottomDestinations.contains(destination) ? destination : nil)
            primary.wrappedValue = nil
            bottom.wrappedValue = nil
            XCTAssertEqual(model.selectedDestination, destination)
        }
        primary.wrappedValue = .discover
        bottom.wrappedValue = .home
        XCTAssertEqual(model.selectedDestination, .discover)
        bottom.wrappedValue = .settings
        XCTAssertEqual(model.selectedDestination, .settings)
        XCTAssertNil(primary.wrappedValue)
        bottom.wrappedValue = .activity
        primary.wrappedValue = .activity
        XCTAssertEqual(model.selectedDestination, .activity)
    }

    func testSidebarSettingsPrecedesActivityAsAMainWindowDestination() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let shell = try String(contentsOf: root.appending(path: "Features/AppRootView.swift"), encoding: .utf8)
        let settings = try XCTUnwrap(shell.range(of: "destinationLabel(.settings)"))
        let activity = try XCTUnwrap(shell.range(of: "destinationLabel(.activity)"))
        XCTAssertTrue(settings.lowerBound < activity.lowerBound)
        XCTAssertFalse(shell.contains("@Environment(\\.openSettings)"))
        XCTAssertTrue(shell.contains("SettingsView(model: model"))
        XCTAssertFalse(shell.contains(".selectionDisabled()"))
    }

    func testSettingsAndCommandCommaRouteToTheMainWindowWithoutASeparateScene() throws {
        _ = try XCTUnwrap(AppDestination(rawValue: "settings"))
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let scene = try String(contentsOf: root.appending(path: "CellarApp.swift"), encoding: .utf8)
        let commands = try String(contentsOf: root.appending(path: "Features/AppCommands.swift"), encoding: .utf8)
        XCTAssertFalse(scene.contains("Settings {"))
        XCTAssertTrue(commands.contains("CommandGroup(replacing: .appSettings)"))
        XCTAssertTrue(commands.contains("model.showDestination(.settings)"))
        XCTAssertTrue(commands.contains(".keyboardShortcut(\",\", modifiers: .command)"))
        XCTAssertFalse(commands.contains("openSettings"))
    }

    func testSettingsAndActivityNavigationShareStateAndHaveNoHostedConstructionSideEffects() async {
        let model = AppModel.live()
        let root = AppRootView(model: model, updateController: ApplicationUpdateController(updaterEnabled: false))
        var presentations = 0
        for destination in [.settings, .activity, .library] as [AppDestination] {
            for _ in 0..<2 { model.showDestination(destination) { _, _ in presentations += 1 } }
            XCTAssertEqual(model.selectedDestination, destination)
            XCTAssertEqual(root.sidebarSelection(for: AppDestination.bottomDestinations).wrappedValue,
                           AppDestination.bottomDestinations.contains(destination) ? destination : nil)
        }
        await model.refreshOnLaunch()
        XCTAssertEqual(presentations, 6)
        XCTAssertNil(model.refreshedAt)
        XCTAssertNil(model.managers)
        XCTAssertNil(model.activityStore)
        XCTAssertTrue(model.activities.isEmpty)
        XCTAssertFalse(model.operationStore.hasActiveOperations)
        for (language, expected) in [("en", "Settings"), ("zh-Hans", "设置"), ("zh-Hant", "設定")] {
            var title = AppDestination.settings.title
            title.locale = Locale(identifier: language)
            XCTAssertEqual(String(localized: title), expected)
        }
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

    func testSceneAndMenuUseMainWindowSettingsAndSharedIntents() throws {
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
        XCTAssertTrue(commands.contains("model.showDestination(destination) { openWindow(id: $0, value: $1) }"))
        XCTAssertTrue(shell.contains("model.showActivity { openWindow(id: $0, value: $1) }"))
        XCTAssertFalse(scene.contains("Settings {"))
        XCTAssertTrue(scene.contains("SidebarCommands()"))
        XCTAssertTrue(shell.contains("SettingsView(model: model, updateController: updateController"))
        XCTAssertTrue(settings.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"))
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
