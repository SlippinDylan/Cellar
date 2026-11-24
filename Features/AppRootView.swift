import SwiftUI

struct AppRootView: View {
    @FocusedValue(\.discoverBatchAction) private var discoverBatchAction
    @FocusedValue(\.discoverToolbar) private var discoverToolbar
    @FocusedValue(\.libraryTabs) private var libraryTabs
    @FocusedValue(\.libraryUpdateFilter) private var libraryUpdateFilter
    @FocusedValue(\.packageUpdateActions) private var packageUpdateActions
    @StateObject private var uninstall: LibraryUninstallModel
    @State private var parentWindowHeight: CGFloat?
    @ObservedObject var model: AppModel
    @ObservedObject private var operationStore: OperationStore
    private let updateController: ApplicationUpdateController
    @FocusState private var focusedSidebarDestination: AppDestination?
    @State private var libraryQuery = ""
    @State private var librarySearchFocusRequest: UUID?
    @State private var contentWidth: CGFloat = 0
    @State private var libraryTabsWidth: CGFloat = 0
    @State private var libraryFilterWidth: CGFloat = 0

    init(model: AppModel, updateController: ApplicationUpdateController) {
        self.init(model: model, updateController: updateController, uninstall: LibraryUninstallModel(model: model))
    }

    init(model: AppModel, updateController: ApplicationUpdateController, uninstall: LibraryUninstallModel) {
        self.model = model
        _uninstall = StateObject(wrappedValue: uninstall)
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
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    TaskFeedbackView(model: model, maximumHeight: geometry.size.height * 0.45)
                    destinationContent
                }
            }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
                .buttonStyle(.glass)
                .navigationTitle(model.selectedDestination.title)
                .toolbar {
                    if model.selectedDestination == .home {
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
                    if model.selectedDestination == .maintenance {
                        ToolbarItem(id: "maintenance-categories", placement: .navigation) {
                            ToolbarCategoryPicker(selection: $model.selectedMaintenanceCategory,
                                                  label: LocalizedStringResource("Maintenance"), title: { $0.title })
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
                                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { libraryTabsWidth = $0 }
                            }
                        } else {
                            ToolbarItem(id: "library-tabs-collapsed", placement: .automatic) {
                                CatalogToolbarScopeTabs(actions: libraryTabs)
                                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { libraryTabsWidth = $0 }
                            }
                        }
                    }
                    if model.selectedDestination == .library, let libraryUpdateFilter {
                        ToolbarSpacer(.fixed, placement: .automatic)
                        ToolbarItem(id: "library-update-filter", placement: .automatic) {
                            LibraryToolbarUpdateFilter(selection: libraryUpdateFilter)
                                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { libraryFilterWidth = $0 }
                        }
                    }
                    if model.selectedDestination == .discover, let discoverToolbar {
                        ToolbarItem(id: "discover-scopes", placement: .navigation) {
                            DiscoverToolbarScopes(selection: discoverToolbar.scope)
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
                    ToolbarSpacer(.flexible, placement: model.selectedDestination == .library ? .automatic : .primaryAction)
                    if model.selectedDestination == .discover, let discoverToolbar {
                        ToolbarItem(id: "discover-search", placement: .primaryAction) {
                            CatalogToolbarSearchField(text: discoverToolbar.query, focusRequest: discoverToolbar.focusRequest,
                                                      prompt: LocalizedStringResource("Search Software"), onSubmit: discoverToolbar.submit)
                                .frame(width: 360)
                                .glassEffect(.regular, in: Capsule())
                        }
                        .sharedBackgroundVisibility(.hidden)
                        ToolbarSpacer(.fixed, placement: .primaryAction)
                    }
                    if model.selectedDestination == .library {
                        ToolbarItem(id: "library-actions-search", placement: .automatic) {
                            HStack(spacing: 8) {
                                if libraryUpdateFilter?.wrappedValue == .pendingUpdates {
                                    Button("Update All") { packageUpdateActions?.updateAll() }
                                        .disabled(packageUpdateActions?.canUpdateAll != true || model.isBusy)
                                        .buttonStyle(.glass)
                                        .fixedSize()
                                }
                                CatalogToolbarSearchField(text: $libraryQuery, focusRequest: librarySearchFocusRequest,
                                                          prompt: LocalizedStringResource("Search Installed Software"))
                                    .frame(minWidth: 140, maxWidth: 380)
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
                            .frame(width: libraryActionsWidth, alignment: .trailing)
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
        .task { await model.refreshOnLaunch() }
    }

    private var libraryActionsWidth: CGFloat {
        // Leave room for the system's toolbar group insets and fixed spacer.
        max(0, contentWidth - libraryTabsWidth - libraryFilterWidth - 64)
    }

    @ViewBuilder private var contextualToolbarActions: some View {
        switch model.selectedDestination {
        case .discover:
            Button("Batch Install") { discoverBatchAction?() }
                .disabled(discoverBatchAction == nil || model.isBusy)
                .buttonStyle(.automatic)
        default:
            EmptyView()
        }
    }

    private var toolbarControlGroup: some View {
        ControlGroup {
            RefreshToolbarButton(model: model)
            contextualToolbarActions
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
        model.isRefreshing || operationStore.currentOperation?.context.operation == .refresh
            || operationStore.currentOperation?.context.operation == .updateHomebrewMetadata
    }

    @ViewBuilder private var destinationContent: some View {
        switch model.selectedDestination {
        case .home:
            HomeView(model: model)
        case .library:
            LibraryView(model: model, uninstall: uninstall, query: $libraryQuery, searchFocusRequest: $librarySearchFocusRequest)
        case .discover:
            DiscoverView(model: model)
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
        model.isRefreshing || operationStore.currentOperation?.context.operation == .refresh
            || operationStore.currentOperation?.context.operation == .updateHomebrewMetadata
    }
}
