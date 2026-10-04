import SwiftUI

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var coordinator: BatchOperationCoordinator
    @StateObject private var management: LibraryManagementModel
    @State private var scope = CatalogScope.all
    @State private var subtype = LibraryHomebrewSubtype.all
    @State private var managing = false
    @State private var managementScope = LibraryManagementScope.formula
    @State private var query = ""
    @State private var selection: Set<BatchItem> = []
    @FocusState private var searchFocused: Bool

    init(model: AppModel) {
        self.model = model
        coordinator = model.batchCoordinator
        _management = StateObject(wrappedValue: LibraryManagementModel(model: model))
    }

    var body: some View {
        let cards = LibraryCatalog.cards(homebrew: model.homebrew?.snapshot, node: model.node,
                                         homebrewUpdates: model.homebrewUpdateState, nodeUpdates: model.nodeUpdateState,
                                         activeIntent: coordinator.activeIntent, runningItem: coordinator.runningItem)
        let contents = LibraryCatalog.contents(cards, scope: effectiveScope, subtype: effectiveSubtype, query: query)
        let scopedCards = contents.scoped
        let visibleCards = contents.matching
        let runtimes = model.node?.installations ?? []
        let visibleRuntimes = runtimes.filter { LibraryCatalog.matches(query, values: [$0.version]) }
        let runtimeMode = managing && managementScope == .nodeRuntime
        let items = runtimeMode ? runtimeItems(runtimes) : scopedCards.map(\.batchItem)
        let state = LibraryContentState(readStates: readStates, totalCount: runtimeMode ? runtimes.count : scopedCards.count,
                                        matchCount: runtimeMode ? visibleRuntimes.count : visibleCards.count)
        VStack(alignment: .leading, spacing: 16) {
            scopes
            if effectiveScope != .homebrew, let node = model.node {
                Text("Node Environment: \(node.summary.nodeVersion) · npm \(node.summary.npmVersion)")
                    .foregroundStyle(.secondary)
            }
            if managing {
                ViewThatFits(in: .horizontal) {
                    HStack { selectionSummary; Spacer(); uninstallSelection(items) }
                    VStack(alignment: .leading, spacing: 8) { selectionSummary; uninstallSelection(items) }
                }
                Text("Select up to 100 items. Uninstall runs one item at a time.").foregroundStyle(.secondary)
            }
            providerWarnings
            if let error = management.error { Text(error.libraryMessage).foregroundStyle(.secondary) }
            if let result = management.result { LibraryResultView(result: result) }
            ScrollView {
                if state == .available {
                    if runtimeMode { runtimeGrid(visibleRuntimes) }
                    else if managing { managedGrid(visibleCards) }
                    else {
                        CatalogCardGrid(states: visibleCards, isActionEnabled: !model.isBusy) { card, _ in
                            Task { await management.prepare([card.batchItem]) }
                        }
                    }
                } else { emptyContent(state) }
            }
        }
        .padding(24)
        .searchable(text: $query, placement: .toolbar, prompt: Text("Search Installed Software"))
        .searchFocused($searchFocused)
        .focusedSceneValue(\.catalogSearchAction) { searchFocused = true }
        .focusedSceneValue(\.libraryActions, LibraryActions(isManaging: managing, toggleManage: toggleManage))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { toggleManage() } label: { Text(managing ? LocalizedStringResource("Done") : LocalizedStringResource("Manage…")) }
                    .disabled(model.isBusy)
            }
        }
        .sheet(item: confirmationBinding) { plan in
            LibraryUninstallConfirmation(plan: plan, cancel: management.dismissConfirmation) {
                Task {
                    await management.confirmUninstall()
                    selection.removeAll()
                }
            }
        }
        .onChange(of: items) { _, available in selection.formIntersection(available) }
    }

    @ViewBuilder private var scopes: some View {
        if managing {
            ViewThatFits(in: .horizontal) {
                managementPicker.pickerStyle(.segmented).fixedSize(horizontal: true, vertical: false)
                managementPicker.pickerStyle(.menu)
            }
            .onChange(of: managementScope) { selection.removeAll() }
        } else {
            Picker("Library Scope", selection: $scope) {
                ForEach(CatalogScope.allCases, id: \.self) { Text($0.libraryTitle).tag($0) }
            }
            .pickerStyle(.segmented)
            if scope == .homebrew {
                Picker("Homebrew Type", selection: $subtype) {
                    ForEach(LibraryHomebrewSubtype.allCases, id: \.self) { Text($0.libraryTitle).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var managementPicker: some View {
        Picker("Manage Scope", selection: $managementScope) {
            ForEach(LibraryManagementScope.allCases, id: \.self) { Text($0.libraryTitle).tag($0) }
        }
    }

    private var effectiveScope: CatalogScope {
        guard managing else { return scope }
        return managementScope == .formula || managementScope == .cask ? .homebrew : .npm
    }

    private var effectiveSubtype: LibraryHomebrewSubtype {
        guard managing else { return subtype }
        return managementScope == .formula ? .formula : managementScope == .cask ? .cask : .all
    }

    private var readStates: [LibraryReadState] {
        switch effectiveScope {
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

    @ViewBuilder private var providerWarnings: some View {
        if effectiveScope != .npm, homebrewReadState == .failed {
            Label("Homebrew could not be refreshed. Previously loaded items may be out of date. Use Refresh to retry.", systemImage: "exclamationmark.circle")
        }
        if effectiveScope != .homebrew, nodeReadState == .failed {
            Label("Node and npm could not be refreshed. Previously loaded items may be out of date. Use Refresh to retry.", systemImage: "exclamationmark.circle")
        }
    }

    private var selectionSummary: some View {
        let count = String(selection.count)
        let title = String(localized: managementScope.libraryTitle)
        return Text("\(count) Selected · \(title)").font(.headline)
    }

    private func uninstallSelection(_ items: [BatchItem]) -> some View {
        Button("Uninstall Selected…", role: .destructive) {
            Task { await management.prepare(items.filter(selection.contains)) }
        }
        .disabled(selection.isEmpty || model.isBusy)
    }

    private func managedGrid(_ cards: [CatalogCardState]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .top)], alignment: .leading, spacing: 16) {
            ForEach(cards) { card in
                VStack(alignment: .leading, spacing: 8) {
                    selectionControl(card.batchItem)
                    CatalogCardView(state: card, showsPrimaryAction: false) { _ in }
                }
            }
        }
    }

    private func runtimeGrid(_ installations: [NodeInstallation]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .top)], alignment: .leading, spacing: 16) {
            ForEach(installations) { installation in
                if let environment = model.node.map({ LibraryCatalog.context($0.summary) }) {
                    let item = BatchItem.nodeRuntime(.init(version: installation.version, environment: environment))
                    let progress = LibraryCatalog.progress(for: item, intent: coordinator.activeIntent, running: coordinator.runningItem)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Node \(installation.version)").font(.headline)
                            Text("Node Runtime").foregroundStyle(.secondary)
                            if installation.isActive { Label("Current Cellar Environment", systemImage: "checkmark.circle") }
                            if installation.isDefault { Label("nvm Default", systemImage: "star") }
                            if progress == .running {
                                HStack { ProgressView().controlSize(.small); Text("Running") }
                            } else if progress == .queued {
                                Label("Queued", systemImage: "clock")
                            }
                            selectionControl(item)
                            Button("Uninstall…", role: .destructive) { Task { await management.prepare([item]) } }
                                .disabled(model.isBusy)
                                .accessibilityLabel(Text("Uninstall Node \(installation.version)"))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    .accessibilityElement(children: .contain)
                }
            }
        }
    }

    private func selectionControl(_ item: BatchItem) -> some View {
        Toggle(isOn: Binding(get: { selection.contains(item) }, set: { selected in
            if selected { selection.insert(item) } else { selection.remove(item) }
        })) { Text("Select \(item.displayIdentifier)") }
        .toggleStyle(.checkbox)
        .disabled(model.isBusy || (!selection.contains(item) && selection.count >= 100))
    }

    private func runtimeItems(_ installations: [NodeInstallation]) -> [BatchItem] {
        guard let node = model.node else { return [] }
        let environment = LibraryCatalog.context(node.summary)
        return installations.map { .nodeRuntime(.init(version: $0.version, environment: environment)) }
    }

    @ViewBuilder private func emptyContent(_ state: LibraryContentState) -> some View {
        switch state {
        case .loading: ProgressView("Loading Installed Software…").frame(maxWidth: .infinity, minHeight: 180)
        case .failed: ContentUnavailableView("Installed Software Unavailable", systemImage: "exclamationmark.circle", description: Text("Use Refresh to retry reading this scope."))
        case .empty: ContentUnavailableView("No Installed Software", systemImage: "shippingbox", description: Text("This scope has no installed items. Choose another scope or use Refresh."))
        case .noMatches: ContentUnavailableView("No Matching Software", systemImage: "magnifyingglass", description: Text("Try another search or choose a different scope."))
        case .available: EmptyView()
        }
    }

    private var confirmationBinding: Binding<BatchPlan?> {
        Binding(get: { management.confirmation }, set: { if $0 == nil { management.dismissConfirmation() } })
    }

    private func toggleManage() {
        if !managing {
            managementScope = scope == .npm ? .npm : subtype == .cask ? .cask : .formula
        }
        selection.removeAll()
        managing.toggle()
    }
}

struct LibraryActions {
    let isManaging: Bool
    let toggleManage: () -> Void
}

private struct LibraryActionsKey: FocusedValueKey { typealias Value = LibraryActions }

extension FocusedValues {
    var libraryActions: LibraryActions? {
        get { self[LibraryActionsKey.self] }
        set { self[LibraryActionsKey.self] = newValue }
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

extension LibraryManagementScope {
    var libraryTitle: LocalizedStringResource {
        switch self {
        case .formula: LocalizedStringResource("Homebrew · Formula")
        case .cask: LocalizedStringResource("Homebrew · Cask")
        case .npm: LocalizedStringResource("npm")
        case .nodeRuntime: LocalizedStringResource("Node Runtime")
        }
    }
}

extension LibraryManagementError {
    var libraryMessage: LocalizedStringResource {
        switch self {
        case .invalidSelection: LocalizedStringResource("Choose up to 100 items from one provider and type in one Node environment.")
        case .protectedTarget: LocalizedStringResource("Current or default Node versions and protected packages cannot be removed. Choose another target.")
        case .preparationFailed: LocalizedStringResource("Cannot prepare this uninstall. Refresh and check the selected targets.")
        case .executionRefused: LocalizedStringResource("Uninstall could not start because the confirmed state is no longer valid. Refresh and try again.")
        }
    }
}
