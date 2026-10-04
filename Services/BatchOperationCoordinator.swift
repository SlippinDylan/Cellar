import Combine
import Foundation

protocol BatchOperationProviding: Sendable {
    func planHomebrew(_ identity: HomebrewPackageIdentity, operation: BatchOperation) async throws -> HomebrewActionPlan
    func executeHomebrew(_ plan: HomebrewActionPlan) async throws -> HomebrewActionResult
    func refreshHomebrew() async throws -> HomebrewStatus
    func planNPM(_ identity: NPMPackageIdentity, operation: BatchOperation) async throws -> NodeActionPlan
    func executeNPM(_ plan: NodeActionPlan, environment: NodeEnvironmentContext) async throws -> NodeOperationResult
    func refreshNPM(_ environment: NodeEnvironmentContext) async throws -> NodeSnapshot
    func planNodeUninstall(_ identity: NodeRuntimeIdentity) async throws -> NodeActionPlan
    func executeNodeUninstall(_ plan: NodeActionPlan, environment: NodeEnvironmentContext) async throws -> NodeOperationResult
}

enum BatchOperationError: Error, Equatable {
    case busy
    case invalidPlan
    case planUnavailable
    case protectedNode
    case reconciliationUnavailable
}

struct BatchPlan: Identifiable, Sendable {
    let id: UUID
    let intent: BatchIntent
    fileprivate let plans: [BatchProviderPlan]

    var homebrewImpacts: [HomebrewActionPlan] {
        plans.compactMap { if case .homebrew(let plan) = $0 { plan } else { nil } }
    }

    var items: [BatchPreparedItem] {
        zip(intent.items, plans).map { item, plan in
            let status: BatchPreparationStatus = if case .unavailable(let status) = plan { status } else { .ready }
            return BatchPreparedItem(item: item, status: status)
        }
    }

    var executableCount: Int { items.count { $0.status == .ready } }

    var npmBindings: [BatchNPMBinding] {
        zip(intent.items, plans).compactMap { item, prepared in
            guard case .npm(let plan, let environment) = prepared,
                  let destination = plan.confirmedPackageDestination, let registryURL = plan.confirmedInstallRegistry else { return nil }
            return BatchNPMBinding(item: item, environment: environment, destination: destination, registryURL: registryURL, targetVersion: plan.payload.targetVersion)
        }
    }
}

enum BatchPreparationStatus: Sendable { case ready, unavailable, alreadyInstalled }

struct BatchPreparedItem: Identifiable, Sendable {
    let item: BatchItem
    let status: BatchPreparationStatus
    var id: BatchItem { item }
}

struct BatchNPMBinding: Sendable {
    let item: BatchItem
    let environment: NodeEnvironmentContext
    let destination: NodePackageDestination
    let registryURL: URL
    let targetVersion: String?
}

private enum BatchProviderPlan: Sendable {
    case homebrew(HomebrewActionPlan)
    case npm(NodeActionPlan, NodeEnvironmentContext)
    case nodeRuntime(NodeActionPlan, NodeEnvironmentContext)
    case unavailable(BatchPreparationStatus)
}

enum BatchProviderResult: Sendable {
    case homebrew(HomebrewActionResult)
    case npm(NodeOperationResult)
    case nodeRuntime(NodeOperationResult)
}

enum BatchRefreshStatus: String, Codable, Sendable {
    case notNeeded
    case succeeded
    case failed
}

enum BatchRefreshedState: Sendable {
    case homebrew(HomebrewStatus)
    case npm(NodeSnapshot)
    case nodeRuntime(NodeSnapshot)
}

struct BatchExecutionResult: Sendable {
    let outcome: BatchOutcome
    // Provider diagnostics remain session-only, separate from the persisted summary.
    let providerResults: [BatchProviderResult?]
    let refreshStatus: BatchRefreshStatus
    let refreshedState: BatchRefreshedState?
}

struct BatchUpdatePlan: Identifiable, Sendable {
    let id: UUID
    let groups: [BatchPlan]
    var executableCount: Int { groups.reduce(0) { $0 + $1.executableCount } }
}

struct BatchUpdateExecutionResult: Sendable {
    let groups: [BatchExecutionResult]
}

private enum BatchReconciliationKey: Hashable {
    case homebrew
    case node(NodeEnvironmentContext)

    init(_ scope: BatchScope) {
        self = switch scope {
        case .homebrew: .homebrew
        case .npm(let environment), .nodeRuntime(let environment): .node(environment)
        }
    }
}

@MainActor
final class BatchOperationCoordinator: ObservableObject {
    @Published private(set) var preparedPlan: BatchPlan?
    @Published private(set) var activeIntent: BatchIntent?
    @Published private(set) var activeIntents: [BatchIntent] = []
    @Published private(set) var runningItem: BatchItem?
    @Published private(set) var result: BatchExecutionResult?
    private var preparedUpdates: BatchUpdatePlan?
    private let provider: any BatchOperationProviding
    private let operationStore: OperationStore
    private let activityStore: ActivityStore?

    init(provider: any BatchOperationProviding, operationStore: OperationStore, activityStore: ActivityStore? = nil) {
        self.provider = provider
        self.operationStore = operationStore
        self.activityStore = activityStore
    }

    func prepare(_ intent: BatchIntent) async throws -> BatchPlan {
        guard !operationStore.hasActiveOperations else { throw BatchOperationError.busy }
        preparedPlan = nil
        preparedUpdates = nil
        let operationID = operationStore.begin()
        defer { operationStore.end(operationID) }
        let plan = try await operationStore.performCancellable(operationID: operationID) {
            try await self.preparePlan(intent)
        }
        preparedPlan = plan
        return plan
    }

    func prepareUpdates(_ intents: [BatchIntent]) async throws -> BatchUpdatePlan {
        guard !operationStore.hasActiveOperations else { throw BatchOperationError.busy }
        let items = intents.flatMap(\.items)
        guard !intents.isEmpty, intents.allSatisfy({ $0.operation == .update }),
              Set(items).count == items.count else { throw BatchOperationError.invalidPlan }
        preparedPlan = nil
        preparedUpdates = nil
        let operationID = operationStore.begin()
        defer { operationStore.end(operationID) }
        let groups = try await operationStore.performCancellable(operationID: operationID) {
            var groups: [BatchPlan] = []
            for intent in intents { groups.append(try await self.preparePlan(intent)) }
            return groups
        }
        let plan = BatchUpdatePlan(id: UUID(), groups: groups)
        preparedUpdates = plan
        return plan
    }

    private func preparePlan(_ intent: BatchIntent) async throws -> BatchPlan {
        var plans: [BatchProviderPlan] = []
        for item in intent.items {
            try Task.checkCancellation()
            do {
                switch item {
                case .homebrew(let identity):
                    let plan = try await self.provider.planHomebrew(identity, operation: intent.operation)
                    guard plan.targets == [identity], plan.canExecute,
                          plan.action == intent.operation.homebrewAction(for: identity.kind)
                    else { throw BatchOperationError.invalidPlan }
                    plans.append(.homebrew(plan))
                case .npm(let identity):
                    let plan = try await self.provider.planNPM(identity, operation: intent.operation)
                    guard plan.request == NodeActionRequest(action: intent.operation.nodeAction, subject: identity.name)
                    else { throw BatchOperationError.invalidPlan }
                    if intent.operation == .install, plan.payload.alreadyInstalled == true {
                        plans.append(.unavailable(.alreadyInstalled))
                        continue
                    }
                    guard plan.canExecute else { throw BatchOperationError.invalidPlan }
                    if intent.operation == .install || intent.operation == .update {
                        guard plan.confirmedPackageDestination != nil, plan.confirmedInstallRegistry != nil else { throw BatchOperationError.invalidPlan }
                    }
                    plans.append(.npm(plan, identity.environment))
                case .nodeRuntime(let identity):
                    let plan = try await self.provider.planNodeUninstall(identity)
                    guard plan.payload.protectedByCurrent != true, plan.payload.protectedByDefault != true
                    else { throw BatchOperationError.protectedNode }
                    guard plan.request == NodeActionRequest(action: .uninstallNode, subject: identity.version),
                          plan.canExecute
                    else { throw BatchOperationError.invalidPlan }
                    plans.append(.nodeRuntime(plan, identity.environment))
                }
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                guard intent.operation != .uninstall else { throw error }
                let status: BatchPreparationStatus = if case HomebrewClientError.alreadyInstalled = error { .alreadyInstalled } else { .unavailable }
                plans.append(.unavailable(status))
            }
        }
        try Task.checkCancellation()
        return BatchPlan(id: UUID(), intent: intent, plans: plans)
    }

    func execute(_ plan: BatchPlan) async throws -> BatchExecutionResult {
        guard !operationStore.hasActiveOperations else { throw BatchOperationError.busy }
        guard preparedPlan?.id == plan.id else { throw BatchOperationError.planUnavailable }
        preparedPlan = nil
        result = nil
        let results = try await executePlans([plan])
        self.result = results[0]
        return results[0]
    }

    func executeUpdates(_ plan: BatchUpdatePlan) async throws -> BatchUpdateExecutionResult {
        guard !operationStore.hasActiveOperations else { throw BatchOperationError.busy }
        guard preparedUpdates?.id == plan.id else { throw BatchOperationError.planUnavailable }
        preparedUpdates = nil
        result = nil
        return BatchUpdateExecutionResult(groups: try await executePlans(plan.groups))
    }

    private func executePlans(_ plans: [BatchPlan]) async throws -> [BatchExecutionResult] {
        activeIntents = plans.map(\.intent)
        let operationID = operationStore.begin()
        defer {
            runningItem = nil
            activeIntent = nil
            activeIntents = []
            operationStore.end(operationID)
        }
        let executions = try await operationStore.performCancellable(operationID: operationID) {
            var executions: [([BatchItemOutcome], [BatchProviderResult?], Bool)] = []
            for plan in plans {
                self.activeIntent = plan.intent
                executions.append(await self.executeItems(plan))
            }
            return executions
        }
        runningItem = nil
        activeIntent = nil
        activeIntents = []
        // Formula and Cask share one inventory. Reconcile it once after all typed groups.
        var reconciliations: [BatchReconciliationKey: (BatchRefreshStatus, BatchRefreshedState?)] = [:]
        for (plan, execution) in zip(plans, executions) where execution.2 {
            let key = BatchReconciliationKey(plan.intent.scope)
            guard reconciliations[key] == nil else { continue }
            let refresh = Task { try await self.refresh(plan.intent) }
            do { reconciliations[key] = try await refresh.value }
            catch { reconciliations[key] = (.failed, nil) }
        }
        var results: [BatchExecutionResult] = []
        for (plan, execution) in zip(plans, executions) {
            guard let outcome = BatchOutcome(intent: plan.intent, itemOutcomes: execution.0) else {
                preconditionFailure("The coordinator must retain exactly one ordered outcome per item")
            }
            let reconciliation = reconciliations[BatchReconciliationKey(plan.intent.scope)] ?? (.notNeeded, nil)
            results.append(BatchExecutionResult(outcome: outcome, providerResults: execution.1,
                                               refreshStatus: reconciliation.0, refreshedState: reconciliation.1))
            activityStore?.append(outcome.activitySummary)
        }
        // A shared provider failure has one separate warning, without changing item outcomes.
        var reported: Set<BatchReconciliationKey> = []
        for plan in plans {
            let key = BatchReconciliationKey(plan.intent.scope)
            if reconciliations[key]?.0 == .failed, reported.insert(key).inserted {
                activityStore?.append(ActivitySummary(id: UUID(), operation: .refresh, scope: plan.intent.scope.activityScope,
                                                     targetDisplayNames: [], date: Date(), status: .failed, itemOutcomes: []))
            }
        }
        return results
    }

    private func executeItems(_ plan: BatchPlan) async -> ([BatchItemOutcome], [BatchProviderResult?], Bool) {
        var outcomes: [BatchItemOutcome] = []
        var results: [BatchProviderResult?] = []
        var started = false
        for (item, prepared) in zip(plan.intent.items, plan.plans) {
            if case .unavailable = prepared {
                outcomes.append(.init(item: item, status: .failed, userFacingMessage: nil))
                results.append(nil)
                continue
            }
            if Task.isCancelled {
                outcomes.append(.init(item: item, status: .cancelled, userFacingMessage: nil))
                results.append(nil)
                continue
            }
            self.runningItem = item
            started = true
            do {
                let status: BatchItemStatus
                switch prepared {
                case .homebrew(let providerPlan):
                    let result = try await self.provider.executeHomebrew(providerPlan)
                    results.append(.homebrew(result))
                    status = switch result.outcome {
                    case .succeeded: .succeeded
                    case .failed: .failed
                    case .partial: .partiallySucceeded
                    case .stateUnknown: .unknown
                    }
                case .npm(let providerPlan, let environment):
                    let result = try await self.provider.executeNPM(providerPlan, environment: environment)
                    results.append(.npm(result))
                    status = result.batchItemStatus
                case .nodeRuntime(let providerPlan, let environment):
                    let result = try await self.provider.executeNodeUninstall(providerPlan, environment: environment)
                    results.append(.nodeRuntime(result))
                    status = result.status == "ok" && result.exitCode == 0 ? .succeeded : .failed
                case .unavailable: preconditionFailure("Unavailable preparation never enters execution")
                }
                outcomes.append(.init(item: item, status: status, userFacingMessage: nil))
            } catch {
                outcomes.append(.init(item: item, status: error is CancellationError || Task.isCancelled ? .cancelled : .failed,
                                      userFacingMessage: nil))
                results.append(nil)
            }
        }
        return (outcomes, results, started)
    }

    private func refresh(_ intent: BatchIntent) async throws -> (BatchRefreshStatus, BatchRefreshedState?) {
        switch intent.scope {
        case .homebrew:
            let status = try await provider.refreshHomebrew()
            guard let snapshot = status.snapshot, snapshot.sectionErrors[.packages] == nil else {
                throw BatchOperationError.reconciliationUnavailable
            }
            let refreshStatus: BatchRefreshStatus = intent.operation == .update && snapshot.sectionErrors[.outdated] != nil ? .failed : .succeeded
            return (refreshStatus, .homebrew(status))
        case .npm(let environment):
            let snapshot = try await provider.refreshNPM(environment)
            let refreshStatus: BatchRefreshStatus = intent.operation == .update && snapshot.outdatedError != nil ? .failed : .succeeded
            return (refreshStatus, .npm(snapshot))
        case .nodeRuntime(let environment): return (.succeeded, .nodeRuntime(try await provider.refreshNPM(environment)))
        }
    }
}

extension BatchOperation {
    var nodeAction: NodeAction {
        switch self {
        case .install: .installPackage
        case .update: .updatePackage
        case .uninstall: .uninstallPackage
        }
    }

    func homebrewAction(for kind: HomebrewPackageKind) -> HomebrewAction {
        switch self {
        case .install: .install
        case .update: .upgrade
        case .uninstall: kind == .formula ? .uninstallFormula : .uninstallCask
        }
    }
}

private extension BatchScope {
    var activityScope: ActivityScope {
        switch self {
        case .homebrew(let kind): .homebrew(kind)
        case .npm(let environment): .npm(environment)
        case .nodeRuntime(let environment): .nodeRuntime(environment)
        }
    }
}

private extension BatchOutcome {
    var activitySummary: ActivitySummary {
        let operation: ActivityOperationKind = switch intent.operation {
        case .install: .install
        case .update: .update
        case .uninstall: .uninstall
        }
        return ActivitySummary(id: UUID(), operation: operation, scope: intent.scope.activityScope,
                               targetDisplayNames: intent.items.map(\.displayIdentifier), date: Date(), status: status,
                               itemOutcomes: itemOutcomes.map { outcome in
            let reason: ActivityItemReason? = switch outcome.status {
            case .succeeded: nil
            case .failed, .partiallySucceeded: .providerFailure
            case .cancelled: .cancelledByUser
            case .unknown: .stateUnavailable
            }
            return ActivityItemSummary(displayName: outcome.item.displayIdentifier, status: outcome.status, reason: reason)
        })
    }
}
