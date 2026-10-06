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
        XCTAssertEqual(AppDestination.primaryDestinations, [.home, .library, .discover, .tools])
        XCTAssertEqual(AppDestination.bottomDestinations, [.settings, .activity])
        XCTAssertEqual(AppDestination.allCases.map(\.rawValue), ["home", "library", "discover", "tools", "settings", "activity"])
        XCTAssertEqual(AppModel.live().selectedDestination, .home)
        XCTAssertEqual(SettingsPane.allCases, [.general, .sources, .terminal, .about])
    }

    func testSidebarPinsUtilityDestinationsInABottomSafeAreaBar() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let shell = try String(contentsOf: root.appending(path: "Features/AppRootView.swift"), encoding: .utf8)
        XCTAssertTrue(shell.contains("selection: sidebarSelection(for: AppDestination.primaryDestinations)"))
        XCTAssertTrue(shell.contains(".safeAreaBar(edge: .bottom, alignment: .leading, spacing: 0)"))
        XCTAssertTrue(shell.contains("ForEach(AppDestination.bottomDestinations)"))
        XCTAssertTrue(shell.contains("destinations.contains(model.selectedDestination)"))
        let activity = try String(contentsOf: root.appending(path: "Features/Activity/ActivityView.swift"), encoding: .utf8)
        XCTAssertTrue(activity.contains(".onCopyCommand"))
        XCTAssertFalse(activity.contains(".keyboardShortcut(\"c\""))
    }

    func testOwnedSidebarBindingsRetainSharedNavigationAcrossEveryTransition() {
        let model = AppModel.live()
        let view = AppRootView(model: model, updateController: ApplicationUpdateController(updaterEnabled: false))
        let primary = view.sidebarSelection(for: AppDestination.primaryDestinations)
        for destination in AppDestination.allCases {
            model.selectedDestination = destination
            XCTAssertEqual(primary.wrappedValue, AppDestination.primaryDestinations.contains(destination) ? destination : nil)
            primary.wrappedValue = nil
            XCTAssertEqual(model.selectedDestination, destination)
        }
        primary.wrappedValue = .discover
        XCTAssertEqual(model.selectedDestination, .discover)
        model.selectedDestination = .settings
        XCTAssertEqual(model.selectedDestination, .settings)
        XCTAssertNil(primary.wrappedValue)
        model.selectedDestination = .activity
        XCTAssertEqual(model.selectedDestination, .activity)
    }

    func testSidebarSettingsPrecedesActivityAsAMainWindowDestination() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let shell = try String(contentsOf: root.appending(path: "Features/AppRootView.swift"), encoding: .utf8)
        XCTAssertEqual(AppDestination.bottomDestinations, [.settings, .activity])
        XCTAssertTrue(shell.contains("ForEach(AppDestination.bottomDestinations)"))
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

    func testAboutCommandTargetsTheMainWindowAboutPane() throws {
        let model = AppModel.live()
        var presentations = 0

        model.showSettingsPane(.about) { id, identity in
            XCTAssertEqual(id, AppScene.mainWindowID)
            XCTAssertEqual(identity, .main)
            presentations += 1
        }

        XCTAssertEqual(model.selectedDestination, .settings)
        XCTAssertEqual(model.consumePendingSettingsPane(), .about)
        XCTAssertNil(model.consumePendingSettingsPane())
        XCTAssertEqual(presentations, 1)

        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let commands = try String(contentsOf: root.appending(path: "Features/AppCommands.swift"), encoding: .utf8)
        XCTAssertTrue(commands.contains("CommandGroup(replacing: .appInfo)"))
        XCTAssertTrue(commands.contains("model.showSettingsPane(.about)"))
    }

    func testMainWindowAndControlsUseTheRequestedMacOS26Presentation() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let scene = try String(contentsOf: root.appending(path: "CellarApp.swift"), encoding: .utf8)
        let shell = try String(contentsOf: root.appending(path: "Features/AppRootView.swift"), encoding: .utf8)
        let cards = try String(contentsOf: root.appending(path: "Features/Catalog/CatalogCardView.swift"), encoding: .utf8)

        XCTAssertTrue(scene.contains(".frame(minWidth: 1080, minHeight: 720)"))
        XCTAssertTrue(scene.contains(".windowResizability(.contentMinSize)"))
        let detailContent = try XCTUnwrap(shell.range(of: "destinationContent"))
        let splitViewStyle = try XCTUnwrap(shell.range(of: ".navigationSplitViewStyle(.prominentDetail)"))
        XCTAssertTrue(detailContent.lowerBound < splitViewStyle.lowerBound)
        XCTAssertTrue(shell.contains(".buttonStyle(.glass)"))
        XCTAssertFalse(cards.contains(".buttonStyle(.bordered)"))
        XCTAssertTrue(cards.contains(".buttonStyle(.glass)"))
    }

    func testRefreshToolbarShowsProgressInPlaceWithoutAnActivityShortcut() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let shell = try String(contentsOf: root.appending(path: "Features/AppRootView.swift"), encoding: .utf8)
        let home = try String(contentsOf: root.appending(path: "Features/Home/HomeView.swift"), encoding: .utf8)
        let library = try String(contentsOf: root.appending(path: "Features/Library/LibraryView.swift"), encoding: .utf8)
        let environment = try String(contentsOf: root.appending(path: "Features/Tools/EnvironmentSetupView.swift"), encoding: .utf8)
        let runtime = try String(contentsOf: root.appending(path: "Features/Tools/RuntimeToolsView.swift"), encoding: .utf8)

        XCTAssertTrue(shell.contains("operationStore.currentOperation?.context.operation == .refresh"))
        XCTAssertTrue(shell.contains("if isRefreshActive"))
        XCTAssertTrue(shell.contains("ProgressView()"))
        XCTAssertTrue(shell.contains("RefreshToolbarButton(model: model)"))
        XCTAssertTrue(shell.contains("private struct RefreshToolbarButton: View"))
        XCTAssertTrue(shell.contains("@ObservedObject private var operationStore: OperationStore"))
        XCTAssertTrue(shell.contains(".allowsHitTesting(false)"))
        XCTAssertFalse(home.contains("Reading Local Environment"))
        XCTAssertFalse(library.contains("ProgressView(\"Loading Installed Software…\")"))
        XCTAssertFalse(library.contains("ProgressView(\"Checking Package Updates…\")"))
        XCTAssertFalse(library.contains(#"Text("\(providerName): Checking Updates…")"#))
        XCTAssertFalse(environment.contains("case .loading: ProgressView()"))
        XCTAssertFalse(runtime.contains("if runtime.isLoading { ProgressView() }"))
        XCTAssertFalse(shell.contains("ToolbarItem(placement: .status)"))
        XCTAssertFalse(shell.contains("model.showActivity { openWindow(id: $0, value: $1) }"))
        XCTAssertFalse(shell.contains("Cancel Task"))
    }

    func testToolbarActionsUseOneSystemGlassGroupWithIndependentControls() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let shell = try String(contentsOf: root.appending(path: "Features/AppRootView.swift"), encoding: .utf8)
        let toolbarPages = try [
            "Features/Library/LibraryView.swift",
            "Features/Discover/DiscoverView.swift",
            "Features/Activity/ActivityView.swift",
        ].map { try String(contentsOf: root.appending(path: $0), encoding: .utf8) }

        XCTAssertTrue(shell.contains("ToolbarItem(id: \"refreshing-actions\", placement: .primaryAction)"))
        XCTAssertTrue(shell.contains("ToolbarItem(id: \"idle-actions\", placement: .primaryAction)"))
        XCTAssertTrue(shell.contains("ToolbarItem(id: \"library-tabs-expanded\", placement: .automatic)"))
        XCTAssertTrue(shell.contains("ToolbarItem(id: \"library-tabs-collapsed\", placement: .automatic)"))
        XCTAssertFalse(shell.contains("model.selectedDestination == .library ? Text(\"\")"))
        XCTAssertTrue(shell.contains("ControlGroup {"))
        XCTAssertTrue(shell.contains(".controlGroupStyle(.navigation)"))
        XCTAssertFalse(shell.contains("ToolbarItemGroup(placement: .primaryAction)"))
        XCTAssertFalse(shell.contains("@FocusedValue(\\.libraryActions)"))
        XCTAssertTrue(shell.contains("@FocusedValue(\\.discoverBatchAction)"))
        XCTAssertTrue(shell.contains("@FocusedValue(\\.packageUpdateActions)"))
        XCTAssertTrue(shell.contains("@FocusedValue(\\.activityActions)"))
        XCTAssertTrue(shell.contains(".buttonStyle(.automatic)"))
        XCTAssertTrue(shell.contains("ToolbarSpacer(.fixed, placement: .primaryAction)"))
        XCTAssertTrue(shell.contains("ToolbarItem(id: \"library-actions-search\", placement: .automatic)"))
        XCTAssertTrue(shell.contains(".frame(width: 360)"))
        XCTAssertTrue(toolbarPages.allSatisfy { !$0.contains(".toolbar {") })
    }

    func testRunningTasksExposeNoUserCancellationControlsOrIntent() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sources = try [
            "Features/AppRootView.swift",
            "Features/AppCommands.swift",
            "Features/Activity/ActivityView.swift",
            "Features/Discover/DiscoverView.swift",
            "Features/Settings/SettingsView.swift",
            "Models/AppDestination.swift",
            "Services/AppModel.swift",
            "Services/OperationStore.swift",
        ].map { try String(contentsOf: root.appending(path: $0), encoding: .utf8) }.joined(separator: "\n")

        XCTAssertFalse(sources.contains("Cancel Task"))
        XCTAssertFalse(sources.contains("Cancel Search"))
        XCTAssertFalse(sources.contains("Cancellation Requested"))
        XCTAssertFalse(sources.contains("performShellAction(.cancel)"))
        XCTAssertFalse(sources.contains("cancelActiveTask"))
        XCTAssertFalse(sources.contains("case cancel"))
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
        XCTAssertFalse(shell.contains("model.showActivity { openWindow(id: $0, value: $1) }"))
        XCTAssertFalse(scene.contains("Settings {"))
        XCTAssertTrue(scene.contains("SidebarCommands()"))
        XCTAssertTrue(shell.contains("SettingsView(model: model, updateController: updateController"))
        XCTAssertTrue(settings.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"))
        XCTAssertTrue(shell.contains("utilitySidebarRow"))
        XCTAssertTrue(shell.contains("performShellAction(.refresh)"))
        XCTAssertTrue(commands.contains("performShellAction(.refresh)"))
        XCTAssertFalse(commands.contains("performShellAction(.cancel)"))
        XCTAssertTrue(commands.contains(".keyboardShortcut(\"r\", modifiers: .command)"))
        XCTAssertTrue(settings.contains("@AppStorage(\"settings.pane\")"))
        XCTAssertTrue(settings.contains("store: defaults"))
        XCTAssertTrue(settings.contains("changeLanguage(pendingLanguage)"))
        XCTAssertTrue(settings.contains(".onReceive(relaunchController.$selectedLanguage)"))
    }
}
