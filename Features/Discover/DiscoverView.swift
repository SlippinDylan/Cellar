import SwiftUI

struct DiscoverView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var coordinator: BatchOperationCoordinator
    @ObservedObject private var operationStore: OperationStore
    @StateObject private var search: DiscoverSearchModel
    @StateObject private var installation: DiscoverInstallationModel
    @State private var scope = CatalogProviderScope.homebrewFormula
    @State private var query = ""
    @State private var showsBatch = false
    @FocusState private var searchFocused: Bool

    init(model: AppModel) {
        self.model = model
        coordinator = model.batchCoordinator
        operationStore = model.operationStore
        _search = StateObject(wrappedValue: DiscoverSearchModel(dependencies: .live(service: model.service), operationStore: model.operationStore))
        _installation = StateObject(wrappedValue: DiscoverInstallationModel(model: model))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Search Scope", selection: $scope) {
                ForEach(CatalogProviderScope.allCases, id: \.self) { Text($0.cardTitle).tag($0) }
            }
            .pickerStyle(.segmented)
            if scope == .npm, let npm = model.discoverContext.npm { DiscoverNPMContextView(context: npm) }
            ViewThatFits(in: .horizontal) {
                HStack { searchButton; Spacer(); Text("Search returns up to 50 results.").foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 8) { searchButton; Text("Search returns up to 50 results.").foregroundStyle(.secondary) }
            }
            if let error = installation.error { Label { Text(error.discoverMessage) } icon: { Image(systemName: "exclamationmark.circle") } }
            if let result = installation.result { DiscoverInstallResultView(result: result) }
            ScrollView {
                if search.state == .available, let context = search.resultContext {
                    CatalogCardGrid(states: cards, isActionEnabled: !model.isBusy) { card, _ in
                        Task { await installation.install(card, context: context) }
                    }
                } else { searchContent }
            }
        }
        .padding(24)
        .searchable(text: $query, placement: .toolbar, prompt: Text("Search Software"))
        .searchFocused($searchFocused)
        .onSubmit(of: .search, runSearch)
        .focusedSceneValue(\.catalogSearchAction) { searchFocused = true }
        .focusedSceneValue(\.discoverBatchAction, openBatch)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Batch Install…", action: openBatch).disabled(model.isBusy)
            }
        }
        .sheet(isPresented: $showsBatch) {
            DiscoverBatchInstallSheet(installation: installation, context: model.discoverContext, initialScope: scope)
        }
        .onChange(of: query) { search.invalidate() }
        .onChange(of: scope) { search.invalidate() }
        .onChange(of: model.discoverContext) { _, context in
            // Mutation reconciliation updates cards from local state; environment changes invalidate npm search.
            if scope == .npm, search.resultContext?.npm != context.npm { search.invalidate() }
        }
        .onAppear { searchFocused = true }
        .onDisappear { search.invalidate() }
    }

    private var cards: [CatalogCardState] {
        search.results.map { result in
            result.card(homebrew: model.homebrew?.snapshot, node: model.node, activeIntent: coordinator.activeIntent,
                        running: coordinator.runningItem, canInstall: scope == .npm ? !model.nodeRefreshFailed : !model.homebrewRefreshFailed)
        }
    }

    private var searchButton: some View {
        Button("Search", action: runSearch)
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (model.isBusy && search.state != .loading))
    }

    private func runSearch() {
        let term = query
        let selectedScope = scope
        let context = model.discoverContext
        Task { await search.search(term, scope: selectedScope, context: context) }
    }

    private func openBatch() { installation.dismissPreview(); showsBatch = true }

    @ViewBuilder private var searchContent: some View {
        let state = search.state == .idle ? DiscoverSearchModel.guidance(scope, context: model.discoverContext) ?? .idle : search.state
        switch state {
        case .loading:
            VStack(spacing: 12) {
                ProgressView().accessibilityLabel("Searching Software")
                Button("Cancel Search") { operationStore.cancelActiveTask() }.disabled(operationStore.activeTask?.canCancel != true)
            }.frame(maxWidth: .infinity, minHeight: 180)
        case .idle: ContentUnavailableView("Find Software", systemImage: "magnifyingglass", description: Text("Choose a scope, enter a name, then press Return or Search."))
        case .empty: ContentUnavailableView("No Matching Software", systemImage: "magnifyingglass", description: Text("Try another search or choose a different scope."))
        case .failed: ContentUnavailableView("Search Unavailable", systemImage: "exclamationmark.circle", description: Text("Check this source and try Search again. Installed software remains available in Library."))
        case .cancelled: ContentUnavailableView("Search Cancelled", systemImage: "stop.circle", description: Text("Press Search to try again."))
        case .busy: ContentUnavailableView("Another Task Is Running", systemImage: "clock", description: Text("Wait for the current task to finish, then press Search."))
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

struct DiscoverNPMContextView: View {
    let context: DiscoverNPMContext
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Registry: \(context.registryURL.absoluteString)").textSelection(.enabled)
            Text("Node Environment: \(context.environment.nodeVersion) · npm \(context.environment.npmVersion)")
        }.foregroundStyle(.secondary)
    }
}
