import SwiftUI

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var coordinator: BatchOperationCoordinator
    @ObservedObject private var operationStore: OperationStore
    @StateObject private var uninstall: LibraryUninstallModel
    @State private var selectedTab = CatalogScopeTab.all
    @State private var lastBrewTab = CatalogScopeTab.brewAll
    @State private var query = ""
    @State private var searchFocusRequest: UUID?

    init(model: AppModel) {
        self.model = model
        coordinator = model.batchCoordinator
        operationStore = model.operationStore
        _uninstall = StateObject(wrappedValue: LibraryUninstallModel(model: model))
    }

    var body: some View {
        libraryContent(for: selectedTab)
        .focusedSceneValue(\.catalogSearchAction) { searchFocusRequest = UUID() }
        .focusedSceneValue(\.librarySearch, LibrarySearchContext(text: $query, focusRequest: searchFocusRequest))
        .focusedSceneValue(\.libraryTabs, CatalogScopeTabActions(selected: selectedTab) { selectedTab = $0 })
        .onChange(of: selectedTab) { _, tab in
            if tab == .brew {
                selectedTab = lastBrewTab
            } else if tab.isBrew {
                lastBrewTab = tab
            }
        }
        .sheet(item: confirmationBinding) { plan in
            LibraryUninstallConfirmation(plan: plan, cancel: uninstall.dismissConfirmation) {
                Task { await uninstall.confirmUninstall() }
            }
        }
    }

    private func libraryContent(for tab: CatalogScopeTab) -> some View {
        let cards = LibraryCatalog.cards(homebrew: model.homebrew?.snapshot, node: model.node,
                                         homebrewUpdates: model.homebrewUpdateState, nodeUpdates: model.nodeUpdateState,
                                         activeIntent: coordinator.activeIntent, runningItem: coordinator.runningItem,
                                         stage: operationStore.currentOperation?.context.stage)
        let contents = LibraryCatalog.contents(cards, scope: tab.scope, subtype: tab.subtype, query: query)
        let state = LibraryContentState(readStates: readStates(for: tab.scope), totalCount: contents.scoped.count,
                                        matchCount: contents.matching.count)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                providerWarnings(for: tab.scope)
                if let error = uninstall.error { Text(error.libraryMessage).foregroundStyle(.secondary) }
                if let reason = uninstall.failureReason { Text(reason.message).foregroundStyle(.secondary) }
                if let result = uninstall.result { LibraryResultView(result: result) }
                if state == .available {
                    CatalogCardGrid(states: contents.matching, minimumCardWidth: 360, isActionEnabled: !model.isBusy) { card, _ in
                        Task { await uninstall.prepare(card.batchItem) }
                    }
                } else { emptyContent(state) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentMargins(24, for: .scrollContent)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    private var confirmationBinding: Binding<BatchPlan?> {
        Binding(get: { uninstall.confirmation }, set: { if $0 == nil { uninstall.dismissConfirmation() } })
    }

}

struct LibrarySearchContext {
    let text: Binding<String>
    let focusRequest: UUID?
}

private struct LibrarySearchKey: FocusedValueKey { typealias Value = LibrarySearchContext }
private struct LibraryTabsKey: FocusedValueKey { typealias Value = CatalogScopeTabActions }

extension FocusedValues {
    var librarySearch: LibrarySearchContext? {
        get { self[LibrarySearchKey.self] }
        set { self[LibrarySearchKey.self] = newValue }
    }

    var libraryTabs: CatalogScopeTabActions? {
        get { self[LibraryTabsKey.self] }
        set { self[LibraryTabsKey.self] = newValue }
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
