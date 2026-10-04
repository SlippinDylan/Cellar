import SwiftUI

struct UpdatesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var coordinator: BatchOperationCoordinator
    @StateObject private var updates: PackageUpdatesModel
    @State private var scope = CatalogScope.all
    @State private var subtype = LibraryHomebrewSubtype.all

    init(model: AppModel) {
        self.model = model
        coordinator = model.batchCoordinator
        _updates = StateObject(wrappedValue: PackageUpdatesModel(model: model))
    }

    private var visible: [CatalogCardState] { UpdatesCatalog.visible(model.updateCards, scope: scope, subtype: subtype) }
    private var updateCount: Int { visible.count { $0.primaryAction == .update } }
    private var displayedCount: String { String(updateCount) }
    private var states: [HomePackageUpdateState] {
        switch scope {
        case .all: [brewState, npmState]
        case .homebrew: [brewState]
        case .npm: [npmState]
        }
    }
    private var brewState: HomePackageUpdateState { model.homebrewRefreshFailed ? .failed : model.homebrewUpdateState }
    private var npmState: HomePackageUpdateState { model.nodeRefreshFailed ? .failed : model.nodeUpdateState }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Update Scope", selection: $scope) {
                    ForEach(CatalogScope.allCases, id: \.self) { Text($0.libraryTitle).tag($0) }
                }.pickerStyle(.segmented)
                if scope == .homebrew {
                    Picker("Homebrew Type", selection: $subtype) {
                        ForEach(LibraryHomebrewSubtype.allCases, id: \.self) { Text($0.libraryTitle).tag($0) }
                    }.pickerStyle(.segmented)
                }
                Text(currentScopeTitle).font(.headline)
                Text("\(displayedCount) Updates in This Scope").foregroundStyle(.secondary)
                if scope != .npm { providerStatus("Homebrew", state: brewState) }
                if scope != .homebrew {
                    if let node = model.node {
                        Text("Node Environment: \(node.summary.nodeVersion) · npm \(node.summary.npmVersion)").foregroundStyle(.secondary)
                    }
                    providerStatus("npm", state: npmState)
                }
                if states.contains(.failed) || states.contains(.notLoaded) {
                    Button("Check for Package Updates") { Task { await model.retryPackageUpdateChecks() } }
                        .disabled(model.isBusy || model.refreshedAt == nil)
                }
                if updates.isSubmitting, coordinator.activeIntents.isEmpty { ProgressView("Preparing Updates…") }
                if let error = updates.error { Label { Text(error.updatesMessage) } icon: { Image(systemName: "exclamationmark.circle") } }
                if let result = updates.result { UpdatesResultView(result: result) }
                if !visible.isEmpty {
                    CatalogCardGrid(states: visible, isActionEnabled: !model.isBusy && !updates.isSubmitting) { card, action in
                        if action == .update { Task { await updates.update(card) } }
                    }
                } else {
                    emptyContent(UpdatesContentState(states: states, totalCount: model.updateCards.count, visibleCount: visible.count))
                }
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Update All…", action: prepareAll)
                    .disabled(model.isBusy || updates.isSubmitting || updates.confirmation != nil || updateCount == 0)
            }
        }
        .focusedSceneValue(\.packageUpdateActions, PackageUpdateActions(canUpdateAll: updateCount > 0 && !updates.isSubmitting && updates.confirmation == nil,
                                                                      updateAll: prepareAll, checkUpdates: { Task { await model.retryPackageUpdateChecks() } }))
        .sheet(item: Binding(get: { updates.confirmation }, set: { if $0 == nil { updates.dismissConfirmation() } })) { confirmation in
            UpdatesConfirmationSheet(confirmation: confirmation, updates: updates)
        }
        .task(id: model.refreshedAt) {
            if model.checkedOutdatedRefresh != model.refreshedAt { await model.refreshHomeBackground(after: model.refreshedAt) }
        }
    }

    private var currentScopeTitle: LocalizedStringResource {
        scope == .homebrew && subtype != .all ? (subtype == .formula ? LocalizedStringResource("Homebrew · Formula") : LocalizedStringResource("Homebrew · Cask")) : scope.libraryTitle
    }

    private func prepareAll() {
        let cards = visible
        let capturedScope = scope
        let capturedSubtype = subtype
        Task { await updates.prepareAll(cards, scope: capturedScope, subtype: capturedSubtype) }
    }

    @ViewBuilder private func providerStatus(_ name: LocalizedStringResource, state: HomePackageUpdateState) -> some View {
        let providerName = String(localized: name)
        switch state {
        case .notLoaded: Text("\(providerName): Update Check Not Started").foregroundStyle(.secondary)
        case .loading: HStack { ProgressView().controlSize(.small); Text("\(providerName): Checking Updates…") }
        case .failed: Label("\(providerName): Update Check Failed. Known versions are retained. Use Refresh or check again.", systemImage: "exclamationmark.circle")
        case .available: EmptyView()
        }
    }

    @ViewBuilder private func emptyContent(_ state: UpdatesContentState) -> some View {
        switch state {
        case .notLoaded: ContentUnavailableView("Updates Not Checked", systemImage: "questionmark.circle", description: Text("Use Refresh to read the local environment, then check for package updates."))
        case .loading: ProgressView("Checking Package Updates…").frame(maxWidth: .infinity, minHeight: 180)
        case .failed: ContentUnavailableView("Updates Unavailable", systemImage: "exclamationmark.circle", description: Text("One or more update checks failed. Use Refresh or check again."))
        case .empty: ContentUnavailableView("No Package Updates", systemImage: "checkmark.circle", description: Text("The completed checks found no package updates in this scope."))
        case .noMatches: ContentUnavailableView("No Updates in This Scope", systemImage: "line.3.horizontal.decrease.circle", description: Text("Choose another scope to see the known version differences."))
        case .available: EmptyView()
        }
    }
}

struct UpdatesConfirmationSheet: View {
    let confirmation: UpdatesConfirmation
    @ObservedObject var updates: PackageUpdatesModel
    @Environment(\.dismiss) private var dismiss
    private var eligibleCount: String { String(confirmation.plan.executableCount) }
    private var totalCount: String { String(confirmation.plan.groups.reduce(0) { $0 + $1.items.count }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Update All in This Scope").font(.title2.bold())
            Text(confirmation.scope == .homebrew && confirmation.subtype != .all ? (confirmation.subtype == .formula ? LocalizedStringResource("Homebrew · Formula") : LocalizedStringResource("Homebrew · Cask")) : confirmation.scope.libraryTitle)
            Text("\(eligibleCount) of \(totalCount) Items Can Be Updated")
            Text("Updates run one item at a time. A failure does not stop other items. Completed updates cannot be rolled back.")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(confirmation.plan.groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.intent.scope.updatesTitle).font(.headline)
                            if let binding = group.npmBindings.first {
                                Text("Node Environment: \(binding.environment.nodeVersion) · npm \(binding.environment.npmVersion)")
                                DiscoverNPMDestinationView(destination: binding.destination)
                            }
                            ForEach(group.items) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.item.displayIdentifier).textSelection(.enabled)
                                    Text(item.status.updatesTitle).foregroundStyle(.secondary)
                                    if let binding = group.npmBindings.first(where: { $0.item == item.item }) {
                                        if let target = binding.targetVersion { Text("Available: \(target)") }
                                        Text("Registry: \(binding.registryURL.absoluteString)").foregroundStyle(.secondary)
                                    }
                                }.accessibilityElement(children: .combine)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 320)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { updates.dismissConfirmation(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Update All") { Task { await updates.confirmUpdateAll() } }
                    .keyboardShortcut(.defaultAction).disabled(confirmation.plan.executableCount == 0)
            }
        }.padding(24).frame(width: 520)
    }
}

struct UpdatesResultView: View {
    let result: BatchUpdateExecutionResult
    var body: some View {
        GroupBox("Update Results") {
            VStack(alignment: .leading, spacing: 12) {
                if result.groups.contains(where: { $0.refreshStatus == .failed }) {
                    Label("Updates finished, but an environment could not be refreshed. Item results are retained. Use Refresh to check the current state.", systemImage: "exclamationmark.circle")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(result.groups.enumerated()), id: \.offset) { _, group in
                            Text(group.outcome.intent.scope.updatesTitle).font(.headline)
                            ForEach(group.outcome.itemOutcomes, id: \.item) { outcome in
                                ViewThatFits(in: .horizontal) {
                                    HStack { Text(outcome.item.displayIdentifier); Spacer(); Text(outcome.status.updatesTitle) }
                                    VStack(alignment: .leading) { Text(outcome.item.displayIdentifier); Text(outcome.status.updatesTitle) }
                                }.accessibilityElement(children: .combine)
                                if let reason = outcome.reason { Text(reason.message).foregroundStyle(.secondary) }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(maxHeight: 200)
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension BatchScope {
    var updatesTitle: LocalizedStringResource {
        switch self {
        case .homebrew(.formula): LocalizedStringResource("Homebrew · Formula")
        case .homebrew(.cask): LocalizedStringResource("Homebrew · Cask")
        case .npm: LocalizedStringResource("npm")
        case .nodeRuntime: LocalizedStringResource("Node Runtime")
        }
    }
}

extension BatchPreparationStatus {
    var updatesTitle: LocalizedStringResource { self == .ready ? LocalizedStringResource("Ready to Update") : LocalizedStringResource("Unavailable · Will Not Update") }
}

extension BatchItemStatus {
    var updatesTitle: LocalizedStringResource { self == .succeeded ? LocalizedStringResource("Updated") : libraryTitle }
}

extension PackageUpdateError {
    var updatesMessage: LocalizedStringResource {
        switch self {
        case .unavailable: LocalizedStringResource("Update could not start. Refresh and check the selected packages, then try again.")
        case .staleContext: LocalizedStringResource("The update state or target Node environment changed. Refresh and review the updates again.")
        }
    }
}

struct PackageUpdateActions {
    let canUpdateAll: Bool
    let updateAll: () -> Void
    let checkUpdates: () -> Void
}
private struct PackageUpdateActionsKey: FocusedValueKey { typealias Value = PackageUpdateActions }
extension FocusedValues {
    var packageUpdateActions: PackageUpdateActions? {
        get { self[PackageUpdateActionsKey.self] }
        set { self[PackageUpdateActionsKey.self] = newValue }
    }
}
