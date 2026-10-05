import SwiftUI

struct AppRootView: View {
    @FocusedValue(\.discoverBatchAction) private var discoverBatchAction
    @FocusedValue(\.discoverToolbar) private var discoverToolbar
    @FocusedValue(\.librarySearch) private var librarySearch
    @FocusedValue(\.libraryTabs) private var libraryTabs
    @FocusedValue(\.updatesTabs) private var updatesTabs
    @FocusedValue(\.packageUpdateActions) private var packageUpdateActions
    @FocusedValue(\.activityActions) private var activityActions
    @FocusedValue(\.activitySearch) private var activitySearch
    @FocusedValue(\.settingsPane) private var settingsPane
    @ObservedObject var model: AppModel
    @ObservedObject private var operationStore: OperationStore
    private let updateController: ApplicationUpdateController
    @Environment(\.locale) private var locale

    init(model: AppModel, updateController: ApplicationUpdateController) {
        self.model = model
        self.updateController = updateController
        operationStore = model.operationStore
    }

    var body: some View {
        NavigationSplitView {
            List(AppDestination.primaryDestinations, selection: sidebarSelection(for: AppDestination.primaryDestinations)) { destination in
                destinationLabel(destination)
                    .tag(destination)
            }
            .listStyle(.sidebar)
            .safeAreaBar(edge: .bottom, alignment: .leading, spacing: 0) {
                VStack(spacing: 2) {
                    ForEach(AppDestination.bottomDestinations) { destination in
                        utilitySidebarRow(destination)
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
                    if model.selectedDestination == .tools {
                        ToolbarItem(id: "tools-categories", placement: .navigation) {
                            ToolbarCategoryPicker(selection: $model.selectedToolsCategory,
                                                  label: LocalizedStringResource("Tools Category"), title: { $0.title })
                        }
                    }
                    if model.selectedDestination == .settings, let settingsPane {
                        ToolbarItem(id: "settings-panes", placement: .navigation) {
                            ToolbarCategoryPicker(selection: settingsPane,
                                                  label: LocalizedStringResource("Settings"), title: { $0.title })
                        }
                    }
                    if model.selectedDestination == .library, let libraryTabs {
                        if libraryTabs.selected.isBrew {
                            ToolbarItem(id: "library-tabs-expanded", placement: .navigation) {
                                CatalogToolbarScopeTabs(actions: libraryTabs)
                            }
                        } else {
                            ToolbarItem(id: "library-tabs-collapsed", placement: .navigation) {
                                CatalogToolbarScopeTabs(actions: libraryTabs)
                            }
                        }
                    }
                    if model.selectedDestination == .updates, let updatesTabs {
                        if updatesTabs.selected.isBrew {
                            ToolbarItem(id: "updates-tabs-expanded", placement: .navigation) {
                                CatalogToolbarScopeTabs(actions: updatesTabs)
                            }
                        } else {
                            ToolbarItem(id: "updates-tabs-collapsed", placement: .navigation) {
                                CatalogToolbarScopeTabs(actions: updatesTabs)
                            }
                        }
                    }
                    if model.selectedDestination == .discover, let discoverToolbar {
                        ToolbarItem(id: "discover-scopes", placement: .navigation) {
                            DiscoverToolbarScopes(selection: discoverToolbar.scope)
                        }
                        ToolbarSpacer(.fixed, placement: .navigation)
                        ToolbarItem(id: "discover-search", placement: .navigation) {
                            CatalogToolbarSearchField(text: discoverToolbar.query, focusRequest: discoverToolbar.focusRequest,
                                                      prompt: LocalizedStringResource("Search Software"), onSubmit: discoverToolbar.submit)
                                .frame(width: 360)
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
                    ToolbarSpacer(.flexible, placement: .primaryAction)
                    if isRefreshActive {
                        ToolbarItem(id: "refreshing-actions", placement: .primaryAction) {
                            toolbarControlGroup
                        }
                    } else {
                        ToolbarItem(id: "idle-actions", placement: .primaryAction) {
                            toolbarControlGroup
                        }
                    }
                    if model.selectedDestination == .library, let librarySearch {
                        ToolbarSpacer(.fixed, placement: .primaryAction)
                        ToolbarItem(id: "library-search", placement: .primaryAction) {
                            CatalogToolbarSearchField(text: librarySearch.text, focusRequest: librarySearch.focusRequest,
                                                      prompt: LocalizedStringResource("Search Installed Software"))
                                .frame(width: 360)
                        }
                    }
                    if model.selectedDestination == .activity, let activitySearch {
                        ToolbarSpacer(.fixed, placement: .primaryAction)
                        ToolbarItem(id: "activity-search", placement: .primaryAction) {
                            CatalogToolbarSearchField(text: activitySearch.text, focusRequest: activitySearch.focusRequest,
                                                      prompt: LocalizedStringResource("Search Operation History"))
                                .frame(width: 360)
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
                }
                .toolbar(removing: .title)
        }
        .navigationSplitViewStyle(.prominentDetail)
        .task { await model.refreshOnLaunch() }
    }

    @ViewBuilder private var contextualToolbarActions: some View {
        switch model.selectedDestination {
        case .discover:
            Button("Batch Install") { discoverBatchAction?() }
                .disabled(discoverBatchAction == nil || model.isBusy)
                .buttonStyle(.automatic)
        case .updates:
            Button("Update All") { packageUpdateActions?.updateAll() }
                .disabled(packageUpdateActions?.canUpdateAll != true || model.isBusy)
                .buttonStyle(.automatic)
        case .activity:
            activityToolbarActions
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
    }

    @ViewBuilder private var activityToolbarActions: some View {
        let renderer = ActivityRenderer(locale: locale)
        Menu {
            Picker("Provider", selection: Binding(
                get: { activityActions?.provider ?? .all },
                set: { activityActions?.setProvider($0) }
            )) {
                ForEach(ActivityProviderFilter.allCases, id: \.self) { provider in
                    Text(renderer.provider(provider)).tag(provider)
                }
            }
            Picker("Status", selection: Binding(
                get: { activityActions?.status },
                set: { activityActions?.setStatus($0) }
            )) {
                Text("All Statuses").tag(nil as ActivityStatus?)
                ForEach(ActivityStatus.allCases, id: \.self) { status in
                    Text(status.title).tag(Optional(status))
                }
            }
            Divider()
            Button("Clear Activity Filters") { activityActions?.clearFilters() }
        } label: {
            Label("Filter History", systemImage: "line.3.horizontal.decrease")
        }
        .help("Filter Operation History")
        .disabled(activityActions == nil)
        .buttonStyle(.automatic)

        Button("Copy Summary", systemImage: "doc.on.doc") { activityActions?.copy() }
            .help("Copy Selected Activity Summary")
            .disabled(activityActions?.canCopy != true)
            .buttonStyle(.automatic)

        Button("Session Diagnostics…", systemImage: "stethoscope") { activityActions?.showDiagnostics() }
            .help("Show Current Session Diagnostics")
            .disabled(activityActions == nil)
            .buttonStyle(.automatic)
    }

    @ViewBuilder private var destinationContent: some View {
        if model.selectedDestination == .home { HomeView(model: model) }
        else if model.selectedDestination == .library { LibraryView(model: model) }
        else if model.selectedDestination == .discover { DiscoverView(model: model) }
        else if model.selectedDestination == .updates { UpdatesView(model: model) }
        else if model.selectedDestination == .tools { ToolsView(model: model) }
        else if model.selectedDestination == .settings { SettingsView(model: model, updateController: updateController, relaunchController: .shared) }
        else if model.selectedDestination == .activity { ActivityView(model: model) }
        else { ShellPlaceholderView(destination: model.selectedDestination) }
    }

    func sidebarSelection(for destinations: [AppDestination]) -> Binding<AppDestination?> {
        // Each native List must own its selection, while navigation has one source of truth.
        Binding(get: { destinations.contains(model.selectedDestination) ? model.selectedDestination : nil }, set: { destination in
            if let destination, destinations.contains(destination) { model.selectedDestination = destination }
        })
    }

    private func destinationLabel(_ destination: AppDestination) -> some View {
        Label { Text(destination.title) } icon: { Image(systemName: destination.systemImage) }
    }

    private func utilitySidebarRow(_ destination: AppDestination) -> some View {
        let isSelected = model.selectedDestination == destination

        return Button {
            model.selectedDestination = destination
        } label: {
            destinationLabel(destination)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
            in: .rect(cornerRadius: 6)
        )
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
    }
}
