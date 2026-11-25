import AppKit
import XCTest
@testable import Cellar

@MainActor
final class AppShellTests: XCTestCase {
    func testSettingsIntentsPresentOneMainWindowFromOpenAndClosedStates() {
        for (destination, hasMain) in [(AppDestination.settings, true), (.settings, false)] {
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
        XCTAssertEqual(AppDestination.primaryDestinations, [.home, .library, .discover, .tools, .maintenance])
        XCTAssertEqual(AppDestination.bottomDestinations, [.settings, .about])
        XCTAssertEqual(AppDestination.allCases.map(\.rawValue), ["home", "library", "discover", "tools", "maintenance", "settings", "about"])
        XCTAssertEqual(AppModel.live().selectedDestination, .home)
        XCTAssertEqual(AppModel.live().selectedToolsCategory, .terminal)
        XCTAssertEqual(ToolsCategory.allCases, [.terminal, .homebrewSources, .npmSources, .runtime])
    }

    func testSidebarPinsUtilityDestinationsInABottomSafeAreaBar() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let shell = try String(contentsOf: root.appending(path: "Features/AppRootView.swift"), encoding: .utf8)
        XCTAssertTrue(shell.contains("ForEach(AppDestination.primaryDestinations)"))
        XCTAssertTrue(shell.contains(".safeAreaBar(edge: .bottom, alignment: .leading, spacing: 0)"))
        XCTAssertTrue(shell.contains("ForEach(AppDestination.bottomDestinations)"))
        XCTAssertTrue(shell.contains("let isSelected = model.selectedDestination == destination"))
    }

    func testSidebarKeyboardNavigationCrossesGroupsAndStopsAtTheEdges() {
        let model = AppModel.live()
        let view = AppRootView(model: model, updateController: ApplicationUpdateController(updaterEnabled: false))
        let destinations: [AppDestination] = [.home, .library, .discover, .tools, .maintenance, .settings, .about]
        for (previous, next) in zip(destinations, destinations.dropFirst()) {
            XCTAssertEqual(view.adjacentSidebarDestination(to: previous, forward: true), next)
            XCTAssertEqual(view.adjacentSidebarDestination(to: next, forward: false), previous)
        }
        XCTAssertNil(view.adjacentSidebarDestination(to: .home, forward: false))
        XCTAssertNil(view.adjacentSidebarDestination(to: .about, forward: true))
        XCTAssertEqual(model.selectedDestination, .home)
    }

    func testSidebarAboutFollowsSettings() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let shell = try String(contentsOf: root.appending(path: "Features/AppRootView.swift"), encoding: .utf8)
        XCTAssertEqual(AppDestination.bottomDestinations, [.settings, .about])
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

    func testAboutCommandTargetsTheIndependentMainWindowDestination() throws {
        let model = AppModel.live()
        var presentations = 0

        model.showDestination(.about) { id, identity in
            XCTAssertEqual(id, AppScene.mainWindowID)
            XCTAssertEqual(identity, .main)
            presentations += 1
        }

        XCTAssertEqual(model.selectedDestination, .about)
        XCTAssertEqual(presentations, 1)

        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let commands = try String(contentsOf: root.appending(path: "Features/AppCommands.swift"), encoding: .utf8)
        XCTAssertTrue(commands.contains("CommandGroup(replacing: .appInfo)"))
        XCTAssertTrue(commands.contains("model.showDestination(.about)"))
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
        XCTAssertTrue(cards.contains("CatalogCardPillButtonStyle("),
                      "Catalog actions should use the flat App Store-style capsule button.")
    }

    func testRefreshToolbarShowsProgressInPlaceWithoutAnActivityShortcut() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let shell = try String(contentsOf: root.appending(path: "Features/AppRootView.swift"), encoding: .utf8)
        let home = try String(contentsOf: root.appending(path: "Features/Home/HomeView.swift"), encoding: .utf8)
        let library = try String(contentsOf: root.appending(path: "Features/Library/LibraryView.swift"), encoding: .utf8)
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
            "Features/TaskFeedbackView.swift",
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
        XCTAssertFalse(shell.contains("@FocusedValue(\\.libraryUpdateFilter)"))
        XCTAssertFalse(shell.contains("@FocusedValue(\\.activityActions)"))
        XCTAssertTrue(shell.contains("ToolbarSpacer(.fixed, placement: .primaryAction)"))
        XCTAssertTrue(shell.contains("ToolbarItem(id: \"library-actions-search\", placement: .primaryAction)"))
        XCTAssertEqual(shell.components(separatedBy: ".frame(minWidth: 130, idealWidth: 240, maxWidth: 320)").count - 1, 2)
        let commands = try String(contentsOf: root.appending(path: "Features/AppCommands.swift"), encoding: .utf8)
        XCTAssertTrue(commands.contains("CommandGroup(replacing: .newItem) {}"))
        XCTAssertTrue(toolbarPages.allSatisfy { !$0.contains(".toolbar {") })
    }

    func testRunningTasksExposeNoUserCancellationControlsOrIntent() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sources = try [
            "Features/AppRootView.swift",
            "Features/AppCommands.swift",
            "Features/TaskFeedbackView.swift",
            "Features/Discover/DiscoverView.swift",
            "Features/Discover/DiscoverBatchInstallSheet.swift",
            "Features/Tools/MaintenanceView.swift",
            "Features/Tools/MaintenanceSheets.swift",
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

    func testSettingsNavigationSharesStateAndHasNoHostedConstructionSideEffects() async {
        let model = AppModel.live()
        var presentations = 0
        for destination in [.settings, .tools, .library] as [AppDestination] {
            for _ in 0..<2 { model.showDestination(destination) { _, _ in presentations += 1 } }
            XCTAssertEqual(model.selectedDestination, destination)
        }
        await model.refreshOnLaunch()
        XCTAssertEqual(presentations, 6)
        XCTAssertNil(model.refreshedAt)
        XCTAssertNil(model.managers)
        XCTAssertNil(model.activityStore)
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
        XCTAssertFalse(model.operationStore.hasActiveOperations)
    }

    func testStartupPolicySkipsTestsAndAlreadyLoadedState() {
        XCTAssertFalse(AppRuntime.shouldRefreshOnLaunch(refreshedAt: nil, environment: ["XCTestConfigurationFilePath": "fixture"]))
        XCTAssertFalse(AppRuntime.shouldRefreshOnLaunch(refreshedAt: Date(), environment: [:]))
        XCTAssertTrue(AppRuntime.shouldRefreshOnLaunch(refreshedAt: nil, environment: [:]))
    }

    func testSharedIntentNavigatesAndBusyRefreshDoesNotStartIO() async {
        let model = AppModel.live()
        await model.performShellAction(.show(.tools))
        XCTAssertEqual(model.selectedDestination, .tools)
        model.isNodeWorking = true
        await model.performShellAction(.refresh)
        XCTAssertNil(model.managers)
        XCTAssertFalse(model.operationStore.hasActiveOperations)
    }

    func testActiveTerminalResultUsesVerifiedStepOutcomesInsteadOfOperationPresence() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let terminal = try String(contentsOf: root.appending(path: "Features/Settings/TerminalSettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(terminal.contains("result.stepOutcomes.enumerated()"))
        XCTAssertTrue(terminal.contains("outcome.status.activityTitle"))
        XCTAssertFalse(terminal.contains("result.operations.enumerated()"))
        XCTAssertFalse(terminal.contains("Plugin Selection Saved"))
        XCTAssertFalse(terminal.contains("Theme Saved"))
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
        XCTAssertFalse(feedback.contains("showActivity"))
        XCTAssertFalse(commands.contains("showActivity"))
        XCTAssertTrue(commands.contains("model.showDestination(destination) { openWindow(id: $0, value: $1) }"))
        XCTAssertFalse(shell.contains("model.showActivity { openWindow(id: $0, value: $1) }"))
        XCTAssertFalse(scene.contains("Settings {"))
        XCTAssertTrue(scene.contains("SidebarCommands()"))
        XCTAssertTrue(shell.contains("SettingsView(model: model, relaunchController: .shared"))
        XCTAssertTrue(settings.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"))
        XCTAssertTrue(shell.contains("sidebarRow"))
        XCTAssertTrue(shell.contains("performShellAction(.refresh)"))
        XCTAssertTrue(commands.contains("performShellAction(.refresh)"))
        XCTAssertFalse(commands.contains("performShellAction(.cancel)"))
        XCTAssertTrue(commands.contains(".keyboardShortcut(\"r\", modifiers: .command)"))
        XCTAssertFalse(settings.contains("settings.pane"))
        XCTAssertFalse(settings.contains("HomebrewSourcesView"))
        XCTAssertFalse(settings.contains("NPMRegistrySettingsView"))
        XCTAssertFalse(settings.contains("TerminalSettingsView"))
        XCTAssertTrue(settings.contains("changeLanguage(pendingLanguage)"))
        XCTAssertTrue(settings.contains(".onReceive(relaunchController.$selectedLanguage)"))
    }
}
