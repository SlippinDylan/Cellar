import SwiftUI

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var coordinator: BatchOperationCoordinator
    @ObservedObject private var operationStore: OperationStore
    @ObservedObject private var uninstall: LibraryUninstallModel
    @StateObject private var updates: PackageUpdatesModel
    @State private var selectedTab = CatalogScopeTab.all
    @State private var lastBrewTab = CatalogScopeTab.brewAll
    @State private var updateFilter = LibraryUpdateFilter.all
    @Binding private var query: String
    @Binding private var searchFocusRequest: UUID?

    init(model: AppModel, uninstall: LibraryUninstallModel, query: Binding<String>, searchFocusRequest: Binding<UUID?>) {
        self.model = model
        _query = query
        _searchFocusRequest = searchFocusRequest
        coordinator = model.batchCoordinator
        operationStore = model.operationStore
        self.uninstall = uninstall
        _updates = StateObject(wrappedValue: PackageUpdatesModel(model: model))
    }

    var body: some View {
        let cards = LibraryCatalog.cards(homebrew: model.homebrew?.snapshot, node: model.node,
                                         homebrewUpdates: model.homebrewRefreshFailed ? .failed : model.homebrewUpdateState,
                                         nodeUpdates: model.nodeRefreshFailed ? .failed : model.nodeUpdateState,
                                         activeIntents: coordinator.activeIntents, runningItem: coordinator.runningItem,
                                         stage: operationStore.currentOperation?.context.stage)
        let updateCards = model.updateCards
        let contents = LibraryCatalog.contents(cards, scope: selectedTab.scope, subtype: selectedTab.subtype, query: query,
                                               updateFilter: updateFilter, updateCards: updateCards)
        let targets = LibraryCatalog.updateTargets(for: contents.matching, from: updateCards).filter { model.canMutatePackages(in: $0.batchItem.scope) }
        libraryContent(cards: contents.matching, scopedCount: contents.scoped.count, updateTargets: targets,
                       totalUpdateCount: LibraryCatalog.updateTargets(for: cards, from: updateCards).count)
        .focusedSceneValue(\.catalogSearchAction) { searchFocusRequest = UUID() }
        .focusedSceneValue(\.libraryTabs, CatalogScopeTabActions(selected: selectedTab) { selectedTab = $0 })
        .focusedSceneValue(\.libraryUpdateFilter, $updateFilter)
        .focusedSceneValue(\.packageUpdateActions, PackageUpdateActions(
            canUpdateAll: updateFilter == .pendingUpdates && !targets.isEmpty && canPerformAction,
            updateAll: { prepareAll(targets, scope: selectedTab.scope, subtype: selectedTab.subtype) },
            checkUpdates: { Task { await model.retryPackageUpdateChecks() } }
        ))
        .onChange(of: selectedTab) { _, tab in
            if tab == .brew {
                selectedTab = lastBrewTab
            } else if tab.isBrew {
                lastBrewTab = tab
            }
        }
        .sheet(item: Binding(get: { updates.confirmation }, set: { if $0 == nil { updates.dismissConfirmation() } })) { confirmation in
            UpdatesConfirmationSheet(confirmation: confirmation, updates: updates)
        }
        .task(id: model.refreshedAt) {
            if model.checkedOutdatedRefresh != model.refreshedAt { await model.refreshHomeBackground(after: model.refreshedAt) }
        }
    }

    private func libraryContent(cards: [CatalogCardState], scopedCount: Int, updateTargets: [CatalogCardState], totalUpdateCount: Int) -> some View {
        let state = LibraryContentState(readStates: readStates(for: selectedTab.scope), totalCount: scopedCount, matchCount: cards.count)
        return GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: AppLayout.spacing) {
                    providerWarnings(for: selectedTab.scope)
                    if updates.isSubmitting, let current = operationStore.currentOperation {
                        ProgressView { Text(current.context.stage.title) }
                    }
                    if let error = updates.error { Label { Text(error.updatesMessage) } icon: { Image(systemName: "exclamationmark.circle") } }
                    if let result = updates.result { UpdatesResultView(result: result, dismiss: updates.dismissResult) }
                    if let error = uninstall.error { Text(error.libraryMessage).foregroundStyle(.secondary) }
                    if let reason = uninstall.failureReason { Text(reason.message).foregroundStyle(.secondary) }
                    if let result = uninstall.result { LibraryResultView(result: result, dismiss: uninstall.dismissResult) }
                    if !cards.isEmpty {
                        CatalogCardGrid(states: cards, minimumCardWidth: 360, updateTargets: updateTargets, isActionEnabled: canPerformAction,
                                        isItemActionEnabled: { model.canMutatePackages(in: $0.batchItem.scope) }) { card, action in
                            switch action {
                            case .update: Task { await updates.update(card) }
                            case .uninstall: Task { await uninstall.prepare(card.batchItem) }
                            case .install: preconditionFailure("The installed library does not offer installation")
                            }
                        }
                    } else if updateFilter == .pendingUpdates, state != .loading && state != .failed {
                        if scopedCount > 0 && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { emptyContent(.noMatches) }
                        else { emptyUpdates(UpdatesContentState(states: updateStates, totalCount: totalUpdateCount, visibleCount: 0)) }
                    } else { emptyContent(state) }
                }
                .frame(maxWidth: .infinity, minHeight: max(0, viewport.size.height - AppLayout.spacing * 2),
                       alignment: cards.isEmpty ? .center : .topLeading)
            }
            .contentMargins(AppLayout.spacing, for: .scrollContent)
        }
    }

    private var canPerformAction: Bool {
        !model.isBusy && !updates.isSubmitting && updates.confirmation == nil && uninstall.presentedItem == nil
    }

    private var updateStates: [HomePackageUpdateState] {
        let brew = model.homebrewRefreshFailed ? HomePackageUpdateState.failed : model.homebrewUpdateState
        let npm = model.nodeRefreshFailed ? HomePackageUpdateState.failed : model.nodeUpdateState
        switch selectedTab.scope {
        case .all: return [brew, npm]
        case .homebrew: return [brew]
        case .npm: return [npm]
        }
    }

    private func prepareAll(_ targets: [CatalogCardState], scope: CatalogScope, subtype: LibraryHomebrewSubtype) {
        Task { await updates.prepareAll(targets, scope: scope, subtype: subtype) }
    }

    private func readStates(for scope: CatalogScope) -> [LibraryReadState] {
        switch scope {
        case .all: [homebrewReadState, nodeReadState]
        case .homebrew: [homebrewReadState]
        case .npm: [nodeReadState]
        }
    }

    private var homebrewReadState: LibraryReadState {
        if model.homebrewRefreshFailed || model.homebrew?.snapshot?.sectionErrors[.packages] != nil { return .failed }
        if model.homebrew == nil { return model.refreshedAt == nil || model.isRefreshing ? .loading : .failed }
        return .available
    }

    private var nodeReadState: LibraryReadState {
        if model.nodeRefreshFailed { return .failed }
        if model.node == nil { return model.refreshedAt == nil || model.isRefreshing ? .loading : .failed }
        return .available
    }

    @ViewBuilder private func providerWarnings(for scope: CatalogScope) -> some View {
        if scope != .npm, homebrewReadState == .failed {
            Label("Homebrew could not be refreshed. Previously loaded items may be out of date. Use Refresh to retry.", systemImage: "exclamationmark.circle")
        }
        if scope != .homebrew, nodeReadState == .failed {
            Label("Node and npm could not be refreshed. Previously loaded items may be out of date. Use Refresh to retry.", systemImage: "exclamationmark.circle")
        }
        if scope != .npm, model.homebrewUpdateState == .failed { updateWarning("Homebrew") }
        if scope != .homebrew, model.nodeUpdateState == .failed { updateWarning("npm") }
    }

    private func updateWarning(_ name: LocalizedStringResource) -> some View {
        let providerName = String(localized: name)
        return Label("\(providerName): Update Check Failed. Known versions are retained. Use Refresh or check again.", systemImage: "exclamationmark.circle")
    }

    @ViewBuilder private func emptyUpdates(_ state: UpdatesContentState) -> some View {
        switch state {
        case .notLoaded: ContentUnavailableView("Updates Not Checked", systemImage: "questionmark.circle", description: Text("Use Refresh to read the local environment, then check for package updates."))
        case .loading: EmptyView()
        case .failed: ContentUnavailableView("Updates Unavailable", systemImage: "exclamationmark.circle", description: Text("One or more update checks failed. Use Refresh or check again."))
        case .empty: ContentUnavailableView("No Package Updates", systemImage: "checkmark.circle", description: Text("The completed checks found no package updates in this scope."))
        case .noMatches: ContentUnavailableView("No Updates in This Scope", systemImage: "line.3.horizontal.decrease.circle", description: Text("Choose another scope to see the known version differences."))
        case .available: EmptyView()
        }
    }

    @ViewBuilder private func emptyContent(_ state: LibraryContentState) -> some View {
        switch state {
        case .loading: EmptyView()
        case .failed: ContentUnavailableView("Installed Software Unavailable", systemImage: "exclamationmark.circle", description: Text("Use Refresh to retry reading this scope."))
        case .empty: ContentUnavailableView("No Installed Software", systemImage: "shippingbox", description: Text("This scope has no installed items. Choose another scope or use Refresh."))
        case .noMatches: ContentUnavailableView("No Matching Software", systemImage: "magnifyingglass", description: Text("Try another search or choose a different scope."))
        case .available: EmptyView()
        }
    }

}

private struct LibraryTabsKey: FocusedValueKey { typealias Value = CatalogScopeTabActions }
private struct LibraryUpdateFilterKey: FocusedValueKey { typealias Value = Binding<LibraryUpdateFilter> }

extension FocusedValues {
    var libraryUpdateFilter: Binding<LibraryUpdateFilter>? {
        get { self[LibraryUpdateFilterKey.self] }
        set { self[LibraryUpdateFilterKey.self] = newValue }
    }

    var libraryTabs: CatalogScopeTabActions? {
        get { self[LibraryTabsKey.self] }
        set { self[LibraryTabsKey.self] = newValue }
    }
}

extension LibraryUpdateFilter {
    var title: LocalizedStringResource {
        switch self {
        case .all: LocalizedStringResource("All")
        case .pendingUpdates: LocalizedStringResource("Pending Updates")
        }
    }
}

extension CatalogScope {
    var libraryTitle: LocalizedStringResource {
        switch self {
        case .all: LocalizedStringResource("All")
        case .homebrew: LocalizedStringResource("Homebrew")
        case .npm: LocalizedStringResource("npm")
        }
    }
}

extension LibraryHomebrewSubtype {
    var libraryTitle: LocalizedStringResource {
        switch self {
        case .all: LocalizedStringResource("All")
        case .formula: LocalizedStringResource("Formula")
        case .cask: LocalizedStringResource("Cask")
        }
    }
}

extension LibraryUninstallError {
    var libraryMessage: LocalizedStringResource {
        switch self {
        case .invalidTarget: LocalizedStringResource("Choose one valid installed item.")
        case .protectedTarget: LocalizedStringResource("Current or default Node versions and protected packages cannot be removed. Choose another target.")
        case .preparationFailed: LocalizedStringResource("Cannot prepare this uninstall. Refresh and check the selected targets.")
        case .executionRefused: LocalizedStringResource("Uninstall could not start because the confirmed state is no longer valid. Refresh and try again.")
        }
    }
}
