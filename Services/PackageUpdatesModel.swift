import Combine
import Foundation

@MainActor
final class PackageUpdatesModel: ObservableObject {
    @Published private(set) var confirmation: UpdatesConfirmation?
    @Published private(set) var result: BatchUpdateExecutionResult?
    @Published private(set) var error: PackageUpdateError?
    @Published private(set) var isSubmitting = false
    @Published private(set) var queuedItems: [BatchItem] = []
    @Published private(set) var activeItem: BatchItem?
    private let model: AppModel
    private var pendingQueue: [CatalogCardState] = []
    private var queueTask: Task<Void, Never>?
    private var stopWaitingForBusy = false

    var isQueueActive: Bool { activeItem != nil || !queuedItems.isEmpty }

    init(model: AppModel) { self.model = model }

    func dismissResult() {
        result = nil
    }

    func cancelPendingQueue() {
        pendingQueue.removeAll()
        queuedItems.removeAll()
        stopWaitingForBusy = true
    }

    func enqueueUpdate(_ card: CatalogCardState) {
        guard card.primaryAction == .update, confirmation == nil else { return }
        let item = card.batchItem
        guard activeItem != item, !queuedItems.contains(item) else { return }
        stopWaitingForBusy = false
        pendingQueue.append(card)
        queuedItems.append(item)
        if queueTask == nil {
            queueTask = Task { await processQueue() }
        }
    }

    private func processQueue() async {
        defer {
            activeItem = nil
            queueTask = nil
        }
        while !pendingQueue.isEmpty && !Task.isCancelled {
            while model.isBusy && !stopWaitingForBusy && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard !pendingQueue.isEmpty, !stopWaitingForBusy, !Task.isCancelled else { break }
            let next = pendingQueue.removeFirst()
            let item = next.batchItem
            queuedItems.removeAll { $0 == item }
            activeItem = item
            error = nil
            result = nil
            await update(next)
            var failureLine: String?
            if let err = error {
                failureLine = "\(next.displayName): \(String(localized: err.updatesMessage))"
            } else if result == nil {
                failureLine = "\(next.displayName): \(String(localized: PackageUpdateError.staleContext.updatesMessage))"
            } else if let group = result?.groups.first, group.outcome.status != .succeeded {
                let reason = group.outcome.itemOutcomes.first?.reason?.message
                if let reason {
                    failureLine = "\(next.displayName): \(String(localized: reason))"
                } else {
                    failureLine = "\(next.displayName): \(String(localized: group.outcome.status.libraryTitle))"
                }
            }
            if let failureLine {
                model.recordQueuedBatchFailure(failureLine)
            } else if let group = result?.groups.first, group.refreshStatus == .failed {
                model.recordQueuedBatchFailure("\(next.displayName): \(String(localized: "Updates finished, but an environment could not be refreshed. Item results are retained. Use Refresh to check the current state."))")
            }
            activeItem = nil
        }
        queuedItems.removeAll()
    }

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
        result = nil
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
        } catch {
            let resolved = error as? PackageUpdateError ?? .unavailable
            self.error = resolved
            model.recordQueuedBatchFailure(String(localized: resolved.updatesMessage))
        }
    }

    func dismissConfirmation() {
        guard !isSubmitting else { return }
        confirmation = nil
        result = nil
        error = nil
    }

    func confirmUpdateAll() async {
        guard !isSubmitting, !model.isBusy, result == nil, error == nil, let confirmation else { return }
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
        case .homebrew: model.canMutatePackages(in: intent.scope) && model.homebrewUpdateState == .available
        case .npm: model.canMutatePackages(in: intent.scope) && model.nodeUpdateState == .available
        case .nodeRuntime: false
        }
        let currentItems = Set(model.updateCards.filter { $0.primaryAction == .update }.map(\.batchItem))
        return contextMatches && intent.items.allSatisfy(currentItems.contains)
    }
}

extension AppModel {
    var updateCards: [CatalogCardState] {
        UpdatesCatalog.cards(homebrew: homebrew?.snapshot, node: node,
                             homebrewUpdates: canMutatePackages(in: .homebrew(.formula)) ? homebrewUpdateState : .failed,
                             nodeUpdates: nodeRefreshFailed ? .failed : nodeUpdateState,
                             activeIntents: batchCoordinator.activeIntents, runningItem: batchCoordinator.runningItem,
                             stage: operationStore.currentOperation?.context.stage)
    }

    func prepareUpdateBatch(_ intents: [BatchIntent]) async throws -> BatchUpdatePlan {
        guard !isBusy else { throw BatchOperationError.busy }
        guard intents.allSatisfy({ canMutatePackages(in: $0.scope) }) else { throw BatchOperationError.reconciliationUnavailable }
        return try await batchCoordinator.prepareUpdates(intents)
    }

    func executeUpdateBatch(_ plan: BatchUpdatePlan) async throws -> BatchUpdateExecutionResult {
        guard !isBusy else { throw BatchOperationError.busy }
        guard plan.groups.allSatisfy({ canMutatePackages(in: $0.intent.scope) }) else { throw BatchOperationError.reconciliationUnavailable }
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
