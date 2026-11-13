import Combine
import Foundation

protocol BatchOperationProviding: Sendable {
    func planHomebrew(_ identity: HomebrewPackageIdentity, operation: BatchOperation) async throws -> HomebrewActionPlan
    func executeHomebrew(_ plan: HomebrewActionPlan) async throws -> HomebrewActionResult
    func executeHomebrew(_ plan: HomebrewActionPlan, caskRemovalProgress: CaskRemovalProgressHandler?) async throws -> HomebrewActionResult
    func renewHomebrew(_ plan: HomebrewActionPlan) async throws -> HomebrewActionPlan?
    func renewNPM(_ plan: NodeActionPlan, environment: NodeEnvironmentContext) async throws -> NodeActionPlan?
    func refreshHomebrew() async throws -> HomebrewStatus
    func planNPM(_ identity: NPMPackageIdentity, operation: BatchOperation) async throws -> NodeActionPlan
    func executeNPM(_ plan: NodeActionPlan, environment: NodeEnvironmentContext) async throws -> NodeOperationResult
    func refreshNPM(_ environment: NodeEnvironmentContext) async throws -> NodeSnapshot
    func planNodeUninstall(_ identity: NodeRuntimeIdentity) async throws -> NodeActionPlan
    func executeNodeUninstall(_ plan: NodeActionPlan, environment: NodeEnvironmentContext) async throws -> NodeOperationResult
}

extension BatchOperationProviding {
    func executeHomebrew(_ plan: HomebrewActionPlan, caskRemovalProgress: CaskRemovalProgressHandler?) async throws -> HomebrewActionResult {
        try await executeHomebrew(plan)
    }
}

enum BatchOperationError: Error, Equatable {
    case busy
    case invalidPlan
    case conflictingVersions
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
            let status: BatchPreparationStatus = if case .unavailable(let status, _) = plan { status } else { .ready }
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
    case unavailable(BatchPreparationStatus, ActivityItemReason)
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
    private let diagnosticsStore: ActivityDiagnosticsStore

    init(provider: any BatchOperationProviding, operationStore: OperationStore, activityStore: ActivityStore? = nil,
         diagnosticsStore: ActivityDiagnosticsStore = ActivityDiagnosticsStore()) {
        self.provider = provider
        self.operationStore = operationStore
        self.activityStore = activityStore
        self.diagnosticsStore = diagnosticsStore
    }

    func prepare(_ intent: BatchIntent) async throws -> BatchPlan {
        guard !operationStore.hasActiveOperations else { throw BatchOperationError.busy }
        preparedPlan = nil
        preparedUpdates = nil
        let operationID = operationStore.begin(context: intent.activityContext(stage: .preparing))
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
        let operationID = operationStore.begin(context: .init(operation: .update, scope: nil, targets: items.map(\.displayIdentifier), stage: .preparing))
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
        var items: [BatchItem] = []
        var npmPlans: [String: NodeActionPlan] = [:]
        for input in intent.items {
            var item = input
            try Task.checkCancellation()
            do {
                switch item {
                case .homebrew(let identity):
                    let plan = try await self.provider.planHomebrew(identity, operation: intent.operation)
                    guard plan.targets.count == 1, let canonical = plan.targets.first,
                          canonical.kind == identity.kind, plan.canExecute,
                          plan.action == intent.operation.homebrewAction(for: identity.kind)
                    else { throw BatchOperationError.invalidPlan }
                    item = .homebrew(canonical)
                    if let existing = items.firstIndex(of: item) {
                        if case .unavailable(.unavailable, _) = plans[existing] { plans[existing] = .homebrew(plan) }
                        continue
                    }
                    items.append(item)
                    plans.append(.homebrew(plan))
                case .npm(let identity):
                    let plan = try await self.provider.planNPM(identity, operation: intent.operation)
                    guard plan.request == NodeActionRequest(action: intent.operation.nodeAction, subject: identity.name)
                    else { throw BatchOperationError.invalidPlan }
                    if let name = plan.payload.packageName {
                        if let existing = npmPlans[name] {
                            guard let target = plan.payload.targetVersion, existing.payload.targetVersion == target,
                                  existing.payload.installedVersion == plan.payload.installedVersion,
                                  existing.confirmedInstallRegistry == plan.confirmedInstallRegistry,
                                  existing.confirmedPackageDestination == plan.confirmedPackageDestination
                            else { throw BatchOperationError.conflictingVersions }
                            continue
                        }
                        npmPlans[name] = plan
                    }
                    if intent.operation == .install, plan.payload.alreadyInstalled == true {
                        items.append(item)
                        plans.append(.unavailable(.alreadyInstalled, .alreadyInstalled))
                        continue
                    }
                    guard plan.canExecute else { throw BatchOperationError.invalidPlan }
                    if intent.operation == .install || intent.operation == .update {
                        guard plan.confirmedPackageDestination != nil, plan.confirmedInstallRegistry != nil else { throw BatchOperationError.invalidPlan }
                    }
                    items.append(item)
                    plans.append(.npm(plan, identity.environment))
                case .nodeRuntime(let identity):
                    let plan = try await self.provider.planNodeUninstall(identity)
                    guard plan.payload.protectedByCurrent != true, plan.payload.protectedByDefault != true
                    else { throw BatchOperationError.protectedNode }
                    guard plan.request == NodeActionRequest(action: .uninstallNode, subject: identity.version),
                          plan.canExecute
                    else { throw BatchOperationError.invalidPlan }
                    items.append(item)
                    plans.append(.nodeRuntime(plan, identity.environment))
                }
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                if case BatchOperationError.conflictingVersions = error { throw error }
                guard intent.operation != .uninstall else { throw error }
                if case HomebrewClientError.alreadyInstalled(let identity) = error { item = .homebrew(identity) }
                guard !items.contains(item) else { continue }
                items.append(item)
                let status: BatchPreparationStatus = if case HomebrewClientError.alreadyInstalled = error { .alreadyInstalled } else { .unavailable }
                plans.append(.unavailable(status, .init(error: error, preparing: true)))
                diagnosticsStore.record(operation: intent.activityOperation, scope: intent.scope.activityScope, detail: error.localizedDescription)
            }
        }
        try Task.checkCancellation()
        // Keep preview, execution and outcomes in the same stable order; npm replaces its own executable.
        let ordered = plans.indices.filter { if case .npm(let plan, _) = plans[$0] { plan.payload.packageName != "npm" } else { true } }
            + plans.indices.filter { if case .npm(let plan, _) = plans[$0] { plan.payload.packageName == "npm" } else { false } }
        guard let canonicalIntent = BatchIntent(operation: intent.operation, items: ordered.map { items[$0] }) else { throw BatchOperationError.invalidPlan }
        return BatchPlan(id: UUID(), intent: canonicalIntent, plans: ordered.map { plans[$0] })
    }

    func execute(_ plan: BatchPlan, caskRemovalProgress: CaskRemovalProgressHandler? = nil) async throws -> BatchExecutionResult {
        guard !operationStore.hasActiveOperations else { throw BatchOperationError.busy }
        guard preparedPlan?.id == plan.id else { throw BatchOperationError.planUnavailable }
        preparedPlan = nil
        result = nil
        let results = try await executePlans([plan], caskRemovalProgress: caskRemovalProgress)
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

    private func executePlans(_ plans: [BatchPlan], caskRemovalProgress: CaskRemovalProgressHandler? = nil) async throws -> [BatchExecutionResult] {
        activeIntents = plans.map(\.intent)
        let operationID = operationStore.begin(context: plans[0].intent.activityContext(stage: .executing))
        let total = plans.reduce(0) { $0 + $1.intent.items.count }
        operationStore.updateProgress(completed: 0, total: total)
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
                self.operationStore.updateContext(plan.intent.activityContext(stage: .executing))
                executions.append(await self.executeItems(plan, caskRemovalProgress: caskRemovalProgress))
            }
            return executions
        }
        runningItem = nil
        operationStore.updateContext(.init(operation: plans[0].intent.activityOperation, scope: plans.count == 1 ? plans[0].intent.scope.activityScope : nil,
                                          targets: plans.flatMap { $0.intent.items.map(\.displayIdentifier) }, stage: .reconciling))
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
            activityStore?.append(outcome.activitySummary(id: plan.id))
        }
        // A shared provider failure has one separate warning, without changing item outcomes.
        var reported: Set<BatchReconciliationKey> = []
        for plan in plans {
            let key = BatchReconciliationKey(plan.intent.scope)
            if reconciliations[key]?.0 == .failed, reported.insert(key).inserted {
                activityStore?.append(ActivitySummary(id: UUID(), operation: .refresh, scope: plan.intent.scope.activityScope,
                                                     targetDisplayNames: [], date: Date(), status: .failed, itemOutcomes: [], reason: .stateUnavailable))
            }
        }
        return results
    }

    private func executeItems(_ plan: BatchPlan, caskRemovalProgress: CaskRemovalProgressHandler?) async -> ([BatchItemOutcome], [BatchProviderResult?], Bool) {
        var outcomes: [BatchItemOutcome] = []
        var results: [BatchProviderResult?] = []
        var started = false
        for (item, prepared) in zip(plan.intent.items, plan.plans) {
            defer {
                guard let current = operationStore.currentOperation, let completed = current.completed, let total = current.total else {
                    preconditionFailure("Batch execution owns known progress")
                }
                operationStore.updateProgress(completed: completed + 1, total: total)
            }
            if case .unavailable(let preparation, let reason) = prepared {
                outcomes.append(.init(item: item, status: preparation == .alreadyInstalled ? .skipped : .failed, userFacingMessage: nil, reason: reason))
                results.append(nil)
                continue
            }
            if Task.isCancelled {
                outcomes.append(.init(item: item, status: .cancelled, userFacingMessage: nil, reason: .cancelledByUser))
                results.append(nil)
                continue
            }
            self.runningItem = item
            started = true
            do {
                let status: BatchItemStatus
                let reason: ActivityItemReason?
                switch prepared {
                case .homebrew(let providerPlan):
                    let executionPlan: HomebrewActionPlan
                    if plan.intent.operation == .install || plan.intent.operation == .update {
                        guard let renewed = try await self.provider.renewHomebrew(providerPlan) else {
                            outcomes.append(.init(item: item, status: .skipped, userFacingMessage: nil, reason: .alreadySatisfied))
                            results.append(nil)
                            continue
                        }
                        executionPlan = renewed
                    } else { executionPlan = providerPlan }
                    try Task.checkCancellation()
                    let result = try await self.provider.executeHomebrew(executionPlan, caskRemovalProgress: caskRemovalProgress)
                    results.append(.homebrew(result))
                    status = switch result.outcome {
                    case .succeeded: .succeeded
                    case .failed: .failed
                    case .partial: .partiallySucceeded
                    case .stateUnknown: .unknown
                    }
                    reason = status == .succeeded ? nil : status == .unknown ? .stateUnavailable
                        : result.caskRemovalFailures.first?.recoveryReason ?? .providerFailure
                    diagnosticsStore.record(operation: plan.intent.activityOperation, scope: plan.intent.scope.activityScope,
                                            detail: ([result.postflightError].compactMap { $0 }
                                                + result.caskRemovalFailures.map { "\($0.path): \($0.reason)" }).joined(separator: "\n"),
                                            command: result.command)
                case .npm(let providerPlan, let environment):
                    let executionPlan: NodeActionPlan
                    if plan.intent.operation == .install || plan.intent.operation == .update {
                        guard let renewed = try await self.provider.renewNPM(providerPlan, environment: environment) else {
                            outcomes.append(.init(item: item, status: .skipped, userFacingMessage: nil, reason: .alreadySatisfied))
                            results.append(nil)
                            continue
                        }
                        executionPlan = renewed
                    } else { executionPlan = providerPlan }
                    try Task.checkCancellation()
                    let result = try await self.provider.executeNPM(executionPlan, environment: environment)
                    results.append(.npm(result))
                    status = result.batchItemStatus
                    reason = result.activityReason
                    diagnosticsStore.record(operation: plan.intent.activityOperation, scope: plan.intent.scope.activityScope,
                                            detail: [result.detail ?? "", result.logFile].joined(separator: "\n"))
                case .nodeRuntime(let providerPlan, let environment):
                    let result = try await self.provider.executeNodeUninstall(providerPlan, environment: environment)
                    results.append(.nodeRuntime(result))
                    status = result.batchItemStatus
                    reason = result.activityReason
                    diagnosticsStore.record(operation: plan.intent.activityOperation, scope: plan.intent.scope.activityScope,
                                            detail: [result.detail ?? "", result.logFile].joined(separator: "\n"))
                case .unavailable: preconditionFailure("Unavailable preparation never enters execution")
                }
                outcomes.append(.init(item: item, status: status, userFacingMessage: nil, reason: reason))
            } catch {
                let cancelled = error is CancellationError || Task.isCancelled
                outcomes.append(.init(item: item, status: cancelled ? .cancelled : ActivityItemReason.postWriteStatus(error: error) ?? .failed,
                                      userFacingMessage: nil, reason: cancelled ? .cancelledByUser : .init(error: error)))
                results.append(nil)
                diagnosticsStore.record(operation: plan.intent.activityOperation, scope: plan.intent.scope.activityScope, detail: error.localizedDescription)
            }
        }
        return (outcomes, results, started)
    }

    private func refresh(_ intent: BatchIntent) async throws -> (BatchRefreshStatus, BatchRefreshedState?) {
        switch intent.scope {
        case .homebrew:
            let status = try await provider.refreshHomebrew()
            guard let snapshot = status.snapshot else {
                throw BatchOperationError.reconciliationUnavailable
            }
            let failed = snapshot.sectionErrors[.packages] != nil
                || (intent.operation == .update && snapshot.sectionErrors[.outdated] != nil)
            return (failed ? .failed : .succeeded, .homebrew(status))
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

extension BatchScope {
    var activityScope: ActivityScope {
        switch self {
        case .homebrew(let kind): .homebrew(kind)
        case .npm(let environment): .npm(environment)
        case .nodeRuntime(let environment): .nodeRuntime(environment)
        }
    }
}

extension BatchOutcome {
    func activitySummary(id: UUID) -> ActivitySummary {
        return ActivitySummary(id: id, operation: intent.activityOperation, scope: intent.scope.activityScope,
                               targetDisplayNames: intent.items.map(\.displayIdentifier), date: Date(), status: status,
                               itemOutcomes: itemOutcomes.map { outcome in
            let reason: ActivityItemReason? = switch outcome.status {
            case .succeeded: nil
            case .skipped: .alreadySatisfied
            case .failed, .partiallySucceeded: .providerFailure
            case .cancelled: .cancelledByUser
            case .unknown: .stateUnavailable
            }
            return ActivityItemSummary(displayName: outcome.item.displayIdentifier, status: outcome.status, reason: outcome.reason ?? reason)
        })
    }
}

extension BatchIntent {
    var activityOperation: ActivityOperationKind {
        switch operation { case .install: .install; case .update: .update; case .uninstall: .uninstall }
    }
    func activityContext(stage: ActivityTaskStage) -> ActiveOperationContext {
        .init(operation: activityOperation, scope: scope.activityScope, targets: items.map(\.displayIdentifier), stage: stage)
    }
}
