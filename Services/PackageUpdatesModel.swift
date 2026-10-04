import Combine
import Foundation

@MainActor
final class PackageUpdatesModel: ObservableObject {
    @Published private(set) var confirmation: UpdatesConfirmation?
    @Published private(set) var result: BatchUpdateExecutionResult?
    @Published private(set) var error: PackageUpdateError?
    @Published private(set) var isSubmitting = false
    private let model: AppModel

    init(model: AppModel) { self.model = model }

    func update(_ card: CatalogCardState) async {
        // A duplicate must not overwrite the active attempt's error or outcome.
        guard !isSubmitting, !model.isBusy, confirmation == nil else { return }
        guard card.primaryAction == .update, card.progress == .idle,
              let current = model.updateCards.first(where: { $0.identity == card.identity }),
              current.versionStatus == .behind, current.primaryAction == .update,
              current.currentVersion == card.currentVersion, current.availableVersion == card.availableVersion,
              let intent = BatchIntent(operation: .update, items: [card.batchItem]) else { return }
        isSubmitting = true
        error = nil
        result = nil
        defer { isSubmitting = false }
        do {
            let plan = try await model.prepareBatch(intent)
            try Task.checkCancellation()
            guard valid(plan.intent) else { throw PackageUpdateError.staleContext }
            result = BatchUpdateExecutionResult(groups: [try await model.executeBatch(plan)])
        } catch is CancellationError {
            // Cancelling preparation has no item result because no write has started.
        } catch { self.error = error as? PackageUpdateError ?? .unavailable }
    }

    func prepareAll(_ visible: [CatalogCardState], scope: CatalogScope, subtype: LibraryHomebrewSubtype) async {
        guard !isSubmitting, !model.isBusy, confirmation == nil else { return }
        let intents = UpdatesCatalog.intents(for: UpdatesCatalog.visible(visible, scope: scope, subtype: subtype))
        guard !intents.isEmpty else { return }
        isSubmitting = true
        error = nil
        defer { isSubmitting = false }
        do {
            guard intents.allSatisfy(valid) else { throw PackageUpdateError.staleContext }
            let plan = try await model.prepareUpdateBatch(intents)
            try Task.checkCancellation()
            guard intents.allSatisfy(valid) else { throw PackageUpdateError.staleContext }
            let bindings = plan.groups.flatMap(\.npmBindings)
            if let destination = bindings.first?.destination,
               !bindings.allSatisfy({ $0.destination == destination }) {
                throw PackageUpdateError.staleContext
            }
            confirmation = UpdatesConfirmation(plan: plan, scope: scope, subtype: subtype)
        } catch is CancellationError {
            // The cancelled preview never grants execution authority.
        } catch { self.error = error as? PackageUpdateError ?? .unavailable }
    }

    func dismissConfirmation() { confirmation = nil }

    func confirmUpdateAll() async {
        guard !isSubmitting, !model.isBusy, let confirmation else { return }
        self.confirmation = nil
        isSubmitting = true
        error = nil
        result = nil
        defer { isSubmitting = false }
        do {
            try Task.checkCancellation()
            guard confirmation.plan.groups.allSatisfy({ valid($0.intent) }) else { throw PackageUpdateError.staleContext }
            result = try await model.executeUpdateBatch(confirmation.plan)
        } catch is CancellationError {
            // Once execution starts, its coordinator returns ordered cancellation outcomes.
        } catch { self.error = error as? PackageUpdateError ?? .unavailable }
    }

    private func valid(_ intent: BatchIntent) -> Bool {
        let contextMatches = switch intent.scope {
        case .homebrew: !model.homebrewRefreshFailed && model.homebrewUpdateState == .available
        case .npm(let environment): !model.nodeRefreshFailed && model.nodeUpdateState == .available && model.node.map { LibraryCatalog.context($0.summary) } == environment
        case .nodeRuntime: false
        }
        let currentItems = Set(model.updateCards.filter { $0.primaryAction == .update }.map(\.batchItem))
        return contextMatches && intent.items.allSatisfy(currentItems.contains)
    }
}

extension AppModel {
    var updateCards: [CatalogCardState] {
        UpdatesCatalog.cards(homebrew: homebrew?.snapshot, node: node,
                             homebrewUpdates: homebrewRefreshFailed ? .failed : homebrewUpdateState,
                             nodeUpdates: nodeRefreshFailed ? .failed : nodeUpdateState,
                             activeIntents: batchCoordinator.activeIntents, runningItem: batchCoordinator.runningItem)
    }

    func prepareUpdateBatch(_ intents: [BatchIntent]) async throws -> BatchUpdatePlan {
        guard !isBusy else { throw BatchOperationError.busy }
        return try await batchCoordinator.prepareUpdates(intents)
    }

    func executeUpdateBatch(_ plan: BatchUpdatePlan) async throws -> BatchUpdateExecutionResult {
        guard !isBusy else { throw BatchOperationError.busy }
        let result = try await batchCoordinator.executeUpdates(plan)
        var applied: Set<BatchScope> = []
        var appliedHomebrew = false
        for group in result.groups {
            if case .homebrew = group.outcome.intent.scope {
                guard !appliedHomebrew else { continue }
                appliedHomebrew = true
            } else if !applied.insert(group.outcome.intent.scope).inserted { continue }
            applyBatchResult(group)
        }
        return result
    }

    func retryPackageUpdateChecks() async {
        guard !isBusy else { return }
        checkedOutdatedRefresh = nil
        await refreshHomeBackground(after: refreshedAt)
    }
}
