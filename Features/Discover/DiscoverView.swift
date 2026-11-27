import SwiftUI

struct DiscoverView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var coordinator: BatchOperationCoordinator
    @ObservedObject private var operationStore: OperationStore
    @ObservedObject private var uninstall: LibraryUninstallModel
    @ObservedObject private var search: DiscoverSearchModel
    @ObservedObject private var installation: DiscoverInstallationModel
    @ObservedObject private var updates: PackageUpdatesModel
    @Binding private var scope: DiscoverSearchScope
    @Binding private var query: String
    @State private var searchFocusRequest: UUID?

    init(
        model: AppModel,
        uninstall: LibraryUninstallModel,
        search: DiscoverSearchModel,
        installation: DiscoverInstallationModel,
        updates: PackageUpdatesModel,
        scope: Binding<DiscoverSearchScope>,
        query: Binding<String>
    ) {
        self.model = model
        coordinator = model.batchCoordinator
        operationStore = model.operationStore
        self.uninstall = uninstall
        self.search = search
        self.installation = installation
        self.updates = updates
        _scope = scope
        _query = query
    }

    var body: some View {
        let currentState = search.state(for: scope, context: model.discoverContext)
        let unavailableScopes = scope == .all && currentState == .available ? search.unavailableScopes(for: scope) : []
        let partialScopes = scope == .all && currentState == .available ? search.partialScopes(for: scope) : []
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: AppLayout.spacing) {
                    if currentState == .available, let context = search.resultContext {
                        let visibleCards = cards
                        let updateTargets = LibraryCatalog.updateTargets(for: visibleCards, from: model.updateCards)
                            .filter { model.canMutatePackages(in: $0.batchItem.scope) }
                        CatalogCardGrid(states: visibleCards, minimumCardWidth: 360, updateTargets: updateTargets,
                                        activeOperations: activeOperations,
                                        isActionEnabled: uninstall.presentedItem == nil && !model.isRefreshing,
                                        isUninstallEnabled: !model.isBusy && !installation.isQueueActive && !updates.isQueueActive && uninstall.presentedItem == nil,
                                        isItemActionEnabled: { model.canMutatePackages(in: $0.batchItem.scope) }) { card, selectedAction in
                            switch selectedAction {
                            case .install: installation.enqueueInstall(card, context: context)
                            case .update: updates.enqueueUpdate(card)
                            case .uninstall: Task { await uninstall.prepare(card.batchItem) }
                            }
                        }
                        if !unavailableScopes.isEmpty || !partialScopes.isEmpty {
                            Spacer(minLength: 0)
                            EnvironmentFooterView {
                                ForEach(unavailableScopes, id: \.self) { source in
                                    LabeledContent { Text("Search Unavailable") } label: { Text(source.cardTitle) }
                                }
                                ForEach(partialScopes, id: \.self) { source in
                                    LabeledContent { Text("Some search results could not be loaded.") } label: { Text(source.cardTitle) }
                                }
                            }
                        }
                    } else { searchContent(for: currentState) }
                }
                .frame(maxWidth: .infinity, minHeight: max(0, viewport.size.height - AppLayout.spacing * 2),
                       alignment: currentState == .available ? .topLeading : .center)
            }
            .contentMargins(AppLayout.spacing, for: .scrollContent)
        }
        .focusedSceneValue(\.catalogSearchAction) { searchFocusRequest = UUID() }
        .focusedSceneValue(\.discoverToolbar, DiscoverToolbarContext(scope: $scope, query: $query,
                                                                    focusRequest: searchFocusRequest, submit: runSearch))
        .onChange(of: query) { _, newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                search.invalidate()
            }
        }
        .onDisappear {
            search.cancelInFlightSearch()
        }
        .task(id: model.refreshedAt) {
            if model.checkedOutdatedRefresh != model.refreshedAt { await model.refreshHomeBackground(after: model.refreshedAt) }
        }
    }

    private var activeOperations: [BatchItem: BatchOperation] {
        var map: [BatchItem: BatchOperation] = [:]
        if uninstall.isExecuting, let item = uninstall.presentedItem {
            map[item] = .uninstall
        }
        for intent in coordinator.activeIntents {
            for item in intent.items {
                map[item] = intent.operation
            }
        }
        for item in installation.queuedItems { map[item] = .install }
        if let active = installation.activeItem { map[active] = .install }
        for item in updates.queuedItems { map[item] = .update }
        if let active = updates.activeItem { map[active] = .update }
        return map
    }

    private var cards: [CatalogCardState] {
        let queued = Set(installation.queuedItems).union(updates.queuedItems)
        let activeItems = Set([installation.activeItem, updates.activeItem].compactMap { $0 })
        let inventoryAvailable = model.homebrew?.snapshot?.sectionErrors[.packages] == nil
        let refreshedAt = model.homebrewPackagesRefreshedAt ?? .distantPast
        return search.results(for: scope).map { result in
            let homebrewInventoryIsAuthoritative: Bool
            if case .homebrew(let package) = result {
                let providerScope: CatalogProviderScope = package.identity.kind == .formula ? .homebrewFormula : .homebrewCask
                let scopeSearchedAt = search.searchedAtByScope[providerScope] ?? .distantPast
                homebrewInventoryIsAuthoritative = inventoryAvailable && refreshedAt >= scopeSearchedAt
            } else {
                homebrewInventoryIsAuthoritative = true
            }
            let base = result.card(homebrew: model.homebrew?.snapshot, node: model.node, activeIntent: coordinator.activeIntent,
                                   running: coordinator.runningItem, canInstall: result.identity.providerScope == .npm ? model.discoverContext.npm != nil : model.canMutatePackages(in: .homebrew(.formula)),
                                   stage: operationStore.currentOperation?.context.stage,
                                   homebrewInventoryIsAuthoritative: homebrewInventoryIsAuthoritative)
            let progress: CatalogCardProgress = if base.progress != .idle {
                base.progress
            } else if activeItems.contains(base.batchItem) {
                .running
            } else if queued.contains(base.batchItem) {
                .queued
            } else {
                .idle
            }
            if progress == base.progress { return base }
            return CatalogCardState(
                identity: base.identity,
                displayName: base.displayName,
                description: base.description,
                currentVersion: base.currentVersion,
                availableVersion: base.availableVersion,
                versionStatus: base.versionStatus,
                websiteURL: base.websiteURL,
                progress: progress,
                primaryAction: base.primaryAction,
                icon: base.icon
            ) ?? base
        }
    }

    private func runSearch() {
        let term = query
        guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let selectedScope = scope
        let context = model.discoverContext
        Task { await search.searchGlobally(term, preferredScope: selectedScope, context: context) }
    }

    @ViewBuilder private func searchContent(for currentState: DiscoverSearchState) -> some View {
        let state = currentState == .idle ? DiscoverSearchModel.guidance(scope, context: model.discoverContext) ?? .idle : currentState
        switch state {
        case .loading:
            ProgressView()
                .accessibilityLabel("Searching Software")
                .frame(maxWidth: .infinity, minHeight: 180)
        case .idle: ContentUnavailableView("Find Software", systemImage: "magnifyingglass", description: Text("Choose a scope, enter a name, then press Return."))
        case .empty: ContentUnavailableView("No Matching Software", systemImage: "magnifyingglass", description: Text("Try another search or choose a different scope."))
        case .failed: ContentUnavailableView("Search Unavailable", systemImage: "exclamationmark.circle", description: Text("Check this source, then press Return to retry. Installed software remains available in Library."))
        case .cancelled: ContentUnavailableView("Search Cancelled", systemImage: "stop.circle", description: Text("Press Return to try again."))
        case .busy: ContentUnavailableView("Another Task Is Running", systemImage: "clock", description: Text("Wait for the current task to finish, then press Return."))
        case .homebrewRequired: guidance("Homebrew Required", message: "Use Home to set up Homebrew, or Refresh to check the local environment.")
        case .nodeRequired: guidance("Node and npm Required", message: "Use Home to check Node and npm. Search needs a known Node environment.")
        case .registryRequired: guidance("Registry Required", message: "The effective npm Registry is unavailable. Check Sources and Refresh before searching.")
        case .available: EmptyView()
        }
    }

    private func guidance(_ title: LocalizedStringResource, message: LocalizedStringResource) -> some View {
        VStack(spacing: 12) {
            ContentUnavailableView { Label { Text(title) } icon: { Image(systemName: "shippingbox") } } description: { Text(message) }
            Button("Go to Home") { model.selectedDestination = .home }
        }
    }
}

struct DiscoverToolbarContext {
    let scope: Binding<DiscoverSearchScope>
    let query: Binding<String>
    let focusRequest: UUID?
    let submit: () -> Void
}

private struct DiscoverToolbarKey: FocusedValueKey { typealias Value = DiscoverToolbarContext }

extension FocusedValues {
    var discoverToolbar: DiscoverToolbarContext? {
        get { self[DiscoverToolbarKey.self] }
        set { self[DiscoverToolbarKey.self] = newValue }
    }
}

struct DiscoverToolbarScopes: View {
    @Binding var selection: DiscoverSearchScope

    var body: some View {
        GlassCategoryPicker(selection: $selection, label: "Search Scope") {
            switch $0 {
            case .all: "All"
            case .homebrewFormula: "Formula"
            case .homebrewCask: "Cask"
            case .npm: "NPM"
            }
        }
    }
}

struct DiscoverNPMContextView: View {
    let context: DiscoverNPMContext
    var isDefault = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isDefault { Text("Default Registry: \(context.registryURL.absoluteString)").textSelection(.enabled) }
            else { Text("Registry: \(context.registryURL.absoluteString)").textSelection(.enabled) }
            Text("Node Environment: \(context.environment.nodeVersion) · npm \(context.environment.npmVersion)")
        }.foregroundStyle(.secondary)
    }
}

struct DiscoverNPMDestinationView: View {
    let destination: NodePackageDestination
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Node Executable: \(destination.nodeExecutable)")
            Text("npm Executable: \(destination.npmExecutable)")
            Text("Global Prefix: \(destination.globalPrefix)")
            Text("Global Package Directory: \(destination.globalRoot)")
        }.textSelection(.enabled).foregroundStyle(.secondary)
    }
}
