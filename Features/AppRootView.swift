import SwiftUI

struct AppRootView: View {
    @FocusedValue(\.discoverToolbar) private var discoverToolbar
    @FocusedValue(\.libraryTabs) private var libraryTabs
    @StateObject private var uninstall: LibraryUninstallModel
    @StateObject private var discoverSearch: DiscoverSearchModel
    @StateObject private var discoverInstallation: DiscoverInstallationModel
    @StateObject private var discoverUpdates: PackageUpdatesModel
    @State private var parentWindowHeight: CGFloat?
    @ObservedObject var model: AppModel
    @ObservedObject private var operationStore: OperationStore
    private let updateController: ApplicationUpdateController
    @FocusState private var focusedSidebarDestination: AppDestination?
    @State private var libraryQuery = ""
    @State private var librarySearchFocusRequest: UUID?
    @State private var discoverScope = DiscoverSearchScope.all
    @State private var discoverQuery = ""

    init(model: AppModel, updateController: ApplicationUpdateController) {
        self.init(model: model, updateController: updateController, uninstall: LibraryUninstallModel(model: model))
    }

    init(model: AppModel, updateController: ApplicationUpdateController, uninstall: LibraryUninstallModel) {
        self.model = model
        _uninstall = StateObject(wrappedValue: uninstall)
        _discoverSearch = StateObject(wrappedValue: DiscoverSearchModel(dependencies: .live(service: model.service), operationStore: model.operationStore))
        _discoverInstallation = StateObject(wrappedValue: DiscoverInstallationModel(model: model))
        _discoverUpdates = StateObject(wrappedValue: PackageUpdatesModel(model: model))
        self.updateController = updateController
        operationStore = model.operationStore
    }

    var body: some View {
        NavigationSplitView {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(AppDestination.primaryDestinations) { destination in
                        sidebarRow(destination)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }
            .safeAreaBar(edge: .bottom, alignment: .leading, spacing: 0) {
                VStack(spacing: 2) {
                    ForEach(AppDestination.bottomDestinations) { destination in
                        sidebarRow(destination)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            destinationContent
                .buttonStyle(.glass)
                .navigationTitle(model.selectedDestination.title)
                .toolbar {
                    if model.selectedDestination == .home || model.selectedDestination == .maintenance {
                        ToolbarItem(id: "page-title", placement: .navigation) {
                            Text(model.selectedDestination.title)
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
                    if model.selectedDestination == .tools {
                        ToolbarItem(id: "tools-categories", placement: .navigation) {
                            ToolbarCategoryPicker(selection: $model.selectedToolsCategory,
                                                  label: LocalizedStringResource("Environment"), title: { $0.title })
                        }
                    }
                    if model.selectedDestination == .settings {
                        ToolbarItem(id: "settings-categories", placement: .navigation) {
                            ToolbarCategoryPicker(selection: $model.selectedSettingsCategory,
                                                  label: LocalizedStringResource("Settings"), title: { $0.title })
                        }
                    }
                    if model.selectedDestination == .library, let libraryTabs {
                        if libraryTabs.selected.isBrew {
                            ToolbarItem(id: "library-tabs-expanded", placement: .automatic) {
                                CatalogToolbarScopeTabs(actions: libraryTabs)
                            }
                        } else {
                            ToolbarItem(id: "library-tabs-collapsed", placement: .automatic) {
                                CatalogToolbarScopeTabs(actions: libraryTabs)
                            }
                        }
                    }
                    if model.selectedDestination == .discover, let discoverToolbar {
                        ToolbarItem(id: "discover-scopes", placement: .navigation) {
                            DiscoverToolbarScopes(selection: discoverToolbar.scope)
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
                    ToolbarSpacer(.flexible, placement: .primaryAction)
                    if model.selectedDestination == .discover, let discoverToolbar {
                        ToolbarItem(id: "discover-search", placement: .primaryAction) {
                            CatalogToolbarSearchField(text: discoverToolbar.query, focusRequest: discoverToolbar.focusRequest,
                                                      prompt: LocalizedStringResource("Search Software"), onSubmit: discoverToolbar.submit)
                                .frame(minWidth: 130, idealWidth: 240, maxWidth: 320)
                                .glassEffect(.regular, in: Capsule())
                        }
                        .sharedBackgroundVisibility(.hidden)
                        ToolbarSpacer(.fixed, placement: .primaryAction)
                    }
                    if model.selectedDestination == .library {
                        ToolbarItem(id: "library-actions-search", placement: .primaryAction) {
                            HStack(spacing: 8) {
                                CatalogToolbarSearchField(text: $libraryQuery, focusRequest: librarySearchFocusRequest,
                                                          prompt: LocalizedStringResource("Search Installed Software"))
                                    .frame(minWidth: 130, idealWidth: 240, maxWidth: 320)
                                    .glassEffect(.regular, in: Capsule())
                                RefreshToolbarButton(model: model)
                                    .frame(width: 36, height: 36)
                                    .glassEffect(.regular, in: Circle())
                                    .overlay {
                                        if isRefreshActive {
                                            ProgressView().controlSize(.small)
                                                .allowsHitTesting(false)
                                                .accessibilityHidden(true)
                                        }
                                    }
                            }
                        }
                        .sharedBackgroundVisibility(.hidden)
                    } else if isRefreshActive {
                        ToolbarItem(id: "refreshing-actions", placement: .primaryAction) {
                            toolbarControlGroup
                        }
                    } else {
                        ToolbarItem(id: "idle-actions", placement: .primaryAction) {
                            toolbarControlGroup
                        }
                    }

                }
                .toolbar(removing: .title)
        }
        .navigationSplitViewStyle(.prominentDetail)
        .windowDismissBehavior(operationStore.hasActiveOperations ? .disabled : .automatic)
        .background(LibraryWindowHeightReader { height in
            if parentWindowHeight != height { parentWindowHeight = height }
        })
        .sheet(isPresented: Binding(get: { uninstall.presentedItem != nil && parentWindowHeight != nil }, set: { if !$0 { uninstall.dismissConfirmation() } })) {
            if let parentWindowHeight {
                LibraryUninstallConfirmation(uninstall: uninstall, maximumHeight: parentWindowHeight * 0.7)
            }
        }
        .onChange(of: model.selectedDestination) { previous, current in
            if previous == .library && current != .library {
                libraryQuery = ""
                librarySearchFocusRequest = nil
            }
        }
        .onChange(of: model.discoverContext) { _, context in
            if discoverSearch.resultContext != nil, discoverSearch.resultContext?.npm != context.npm {
                discoverSearch.invalidate()
            }
        }
        .task { await model.refreshOnLaunch() }
        .alert("Operation in Progress", isPresented: Binding(
            get: { operationStore.terminationBlockedNotice },
            set: { if !$0 { operationStore.dismissTerminationBlockedNotice() } }
        )) {
            Button("Got It", role: .cancel) {
                operationStore.dismissTerminationBlockedNotice()
            }
        } message: {
            Text("Wait for the current task to finish before quitting Cellar.")
        }
        .alert("Operation Failed", isPresented: Binding(
            get: { globalFailureAlertMessage != nil },
            set: { if !$0 { dismissGlobalFailureAlert() } }
        )) {
            Button("Got It", role: .cancel) { dismissGlobalFailureAlert() }
        } message: {
            Text(verbatim: globalFailureAlertMessage ?? "")
        }
    }

    private var globalFailureAlertMessage: String? {
        var errors: [String] = []
        if uninstall.presentedItem == nil, let error = uninstall.error {
            if let reason = uninstall.failureReason {
                errors.append("\(String(localized: error.libraryMessage))\n\(String(localized: reason.message))")
            } else {
                errors.append(String(localized: error.libraryMessage))
            }
        }
        if !errors.isEmpty || (!model.isBusy && model.activeModalCount == 0) {
            if let message = model.queuedBatchFailureMessage { errors.append(message) }
        }
        if !model.isBusy,
           model.activeModalCount == 0,
           model.nodePlan == nil,
           model.homebrewPlan == nil,
           model.shellPlan == nil,
           model.terminalConfigurationPlan == nil,
           model.selectedDestination != .home,
           model.selectedDestination != .maintenance {
            errors += [model.nodeOperationError, model.homebrewOperationError, model.shellOperationError].compactMap { $0 }
        }
        errors.removeAll { $0.isEmpty }
        return errors.isEmpty ? nil : Array(Set(errors)).sorted().joined(separator: "\n")
    }

    private func dismissGlobalFailureAlert() {
        model.dismissQueuedBatchFailure()
        if uninstall.presentedItem == nil && uninstall.error != nil {
            uninstall.dismissError()
        }
        model.dismissNodeFeedback()
        model.dismissHomebrewFeedback()
        model.dismissShellFeedback()
    }

    private var toolbarControlGroup: some View {
        ControlGroup {
            RefreshToolbarButton(model: model)
        }
        .controlGroupStyle(.navigation)
        .overlay(alignment: .leading) {
            if isRefreshActive {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 36, height: 36)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var isRefreshActive: Bool {
        toolbarRefreshActive(model: model, operationStore: operationStore)
    }

    @ViewBuilder private var destinationContent: some View {
        switch model.selectedDestination {
        case .home:
            HomeView(model: model)
        case .library:
            LibraryView(model: model, uninstall: uninstall, query: $libraryQuery, searchFocusRequest: $librarySearchFocusRequest)
        case .discover:
            DiscoverView(
                model: model,
                uninstall: uninstall,
                search: discoverSearch,
                installation: discoverInstallation,
                updates: discoverUpdates,
                scope: $discoverScope,
                query: $discoverQuery
            )
        case .tools:
            ToolsView(model: model)
        case .maintenance:
            MaintenanceView(model: model)
        case .settings:
            SettingsView(model: model, relaunchController: .shared)
        case .about:
            AboutView(updateController: updateController)
        }
    }

    func adjacentSidebarDestination(to destination: AppDestination, forward: Bool) -> AppDestination? {
        let destinations = forward ? AppDestination.allCases : AppDestination.allCases.reversed()
        return destinations.drop(while: { $0 != destination }).dropFirst().first
    }

    private func moveSidebarSelection(from destination: AppDestination, forward: Bool) -> KeyPress.Result {
        if let next = adjacentSidebarDestination(to: destination, forward: forward) {
            model.selectedDestination = next
            focusedSidebarDestination = next
        }
        return .handled
    }

    private func destinationLabel(_ destination: AppDestination) -> some View {
        HStack(spacing: 10) {
            Image(systemName: destination.systemImage)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            Text(destination.title)
                .foregroundStyle(.primary)
        }
    }

    private func sidebarRow(_ destination: AppDestination) -> some View {
        let isSelected = model.selectedDestination == destination

        return Button {
            model.selectedDestination = destination
            focusedSidebarDestination = destination
        } label: {
            destinationLabel(destination)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? Color.primary.opacity(0.1) : .clear,
            in: .rect(cornerRadius: 6)
        )
        .focusable()
        .focused($focusedSidebarDestination, equals: destination)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { moveSidebarSelection(from: destination, forward: false) }
        .onKeyPress(.downArrow) { moveSidebarSelection(from: destination, forward: true) }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

@MainActor
func toolbarRefreshActive(model: AppModel, operationStore: OperationStore) -> Bool {
    model.isRefreshing
        || model.homebrewUpdateState == .loading
        || model.nodeUpdateState == .loading
        || operationStore.currentOperation?.context.operation == .refresh
        || operationStore.currentOperation?.context.operation == .updateHomebrewMetadata
}

private struct RefreshToolbarButton: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var operationStore: OperationStore

    init(model: AppModel) {
        self.model = model
        operationStore = model.operationStore
    }

    var body: some View {
        if isRefreshActive {
            Button {} label: {
                Color.clear.frame(width: 18, height: 18)
            }
            .accessibilityLabel("Refresh")
            .help("Refresh Local Environment (⌘R)")
            .disabled(true)
            .allowsHitTesting(false)
            .buttonStyle(.automatic)
        } else {
            Button {
                Task { await model.performShellAction(.refresh) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .help("Refresh Local Environment (⌘R)")
            .disabled(model.isBusy)
            .buttonStyle(.automatic)
        }
    }

    private var isRefreshActive: Bool {
        toolbarRefreshActive(model: model, operationStore: operationStore)
    }
}
