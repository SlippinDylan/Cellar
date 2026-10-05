import AppKit
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
    @State private var searchFocusRequest: UUID?

    init(model: AppModel) {
        self.model = model
        coordinator = model.batchCoordinator
        operationStore = model.operationStore
        _search = StateObject(wrappedValue: DiscoverSearchModel(dependencies: .live(service: model.service), operationStore: model.operationStore))
        _installation = StateObject(wrappedValue: DiscoverInstallationModel(model: model))
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = installation.error { Label { Text(error.discoverMessage) } icon: { Image(systemName: "exclamationmark.circle") } }
                    if installation.isSubmitting, let current = operationStore.currentOperation {
                        ProgressView { Text(current.context.stage.title) }
                    }
                    if let result = installation.result { DiscoverInstallResultView(result: result) }
                    if search.state == .available, let context = search.resultContext {
                        CatalogCardGrid(states: cards, isActionEnabled: !model.isBusy) { card, _ in
                            Task { await installation.install(card, context: context) }
                        }
                    } else { searchContent }
                }
                .frame(maxWidth: .infinity, minHeight: max(0, viewport.size.height - 48),
                       alignment: search.state == .available ? .topLeading : .center)
            }
            .contentMargins(24, for: .scrollContent)
        }
        .focusedSceneValue(\.catalogSearchAction) { searchFocusRequest = UUID() }
        .focusedSceneValue(\.discoverToolbar, DiscoverToolbarContext(scope: $scope, query: $query,
                                                                    focusRequest: searchFocusRequest, submit: runSearch))
        .focusedSceneValue(\.discoverBatchAction, openBatch)
        .sheet(isPresented: $showsBatch) {
            DiscoverBatchInstallSheet(installation: installation, context: model.discoverContext, initialScope: scope)
        }
        .onChange(of: query) { search.invalidate() }
        .onChange(of: scope) { search.invalidate() }
        .onChange(of: model.discoverContext) { _, context in
            // Mutation reconciliation updates cards from local state; environment changes invalidate npm search.
            if scope == .npm, search.resultContext?.npm != context.npm { search.invalidate() }
        }
        .onAppear { searchFocusRequest = UUID() }
        .onDisappear { search.invalidate() }
    }

    private var cards: [CatalogCardState] {
        search.results.map { result in
            result.card(homebrew: model.homebrew?.snapshot, node: model.node, activeIntent: coordinator.activeIntent,
                        running: coordinator.runningItem, canInstall: scope == .npm ? !model.nodeRefreshFailed : !model.homebrewRefreshFailed,
                        stage: operationStore.currentOperation?.context.stage)
        }
    }

    private func runSearch() {
        let term = query
        guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.isBusy || search.state == .loading else { return }
        let selectedScope = scope
        let context = model.discoverContext
        Task { await search.search(term, scope: selectedScope, context: context) }
    }

    private func openBatch() { installation.dismissPreview(); showsBatch = true }

    @ViewBuilder private var searchContent: some View {
        let state = search.state == .idle ? DiscoverSearchModel.guidance(scope, context: model.discoverContext) ?? .idle : search.state
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
    let scope: Binding<CatalogProviderScope>
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

struct DiscoverToolbarScopes: NSViewRepresentable {
    @Binding var selection: CatalogProviderScope

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: [String(localized: "Formula"), String(localized: "Cask"), String(localized: "NPM")],
                                         trackingMode: .selectOne, target: context.coordinator,
                                         action: #selector(Coordinator.selectScope(_:)))
        control.segmentStyle = .automatic
        control.segmentDistribution = .fit
        control.setAccessibilityLabel(String(localized: "Search Scope"))
        updateNSView(control, context: context)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.selectedSegment = switch selection {
        case .homebrewFormula: 0
        case .homebrewCask: 1
        case .npm: 2
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        nsView.fittingSize
    }

    @MainActor final class Coordinator: NSObject {
        var parent: DiscoverToolbarScopes
        init(parent: DiscoverToolbarScopes) { self.parent = parent }

        @objc func selectScope(_ sender: NSSegmentedControl) {
            let scopes = CatalogProviderScope.allCases
            guard scopes.indices.contains(sender.selectedSegment) else { return }
            parent.selection = scopes[sender.selectedSegment]
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
