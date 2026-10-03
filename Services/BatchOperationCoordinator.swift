import Combine
import Foundation

protocol BatchOperationProviding: Sendable {
    func planHomebrew(_ identity: HomebrewPackageIdentity, operation: BatchOperation) async throws -> HomebrewActionPlan
    func executeHomebrew(_ plan: HomebrewActionPlan) async throws -> HomebrewActionResult
    func refreshHomebrew() async throws -> HomebrewStatus
    func planNPM(_ identity: NPMPackageIdentity, operation: BatchOperation) async throws -> NodeActionPlan
    func executeNPM(_ plan: NodeActionPlan, environment: NodeEnvironmentContext) async throws -> NodeOperationResult
    func refreshNPM(_ environment: NodeEnvironmentContext) async throws -> NodeSnapshot
}

enum BatchOperationError: Error, Equatable {
    case busy
    case invalidPlan
    case planUnavailable
}

struct BatchPlan: Identifiable, Sendable {
    let id: UUID
    let intent: BatchIntent
    fileprivate let plans: [BatchProviderPlan]
}

private enum BatchProviderPlan: Sendable {
    case homebrew(HomebrewActionPlan)
    case npm(NodeActionPlan, NodeEnvironmentContext)
}

enum BatchProviderResult: Sendable {
    case homebrew(HomebrewActionResult)
    case npm(NodeOperationResult)
}

enum BatchRefreshStatus: String, Codable, Sendable {
    case notNeeded
    case succeeded
    case failed
}

enum BatchRefreshedState: Sendable {
    case homebrew(HomebrewStatus)
    case npm(NodeSnapshot)
}

struct BatchExecutionResult: Sendable {
    let outcome: BatchOutcome
    // Provider diagnostics remain session-only, separate from the persisted summary.
    let providerResults: [BatchProviderResult?]
    let refreshStatus: BatchRefreshStatus
    let refreshedState: BatchRefreshedState?
}

@MainActor
final class BatchOperationCoordinator: ObservableObject {
    @Published private(set) var preparedPlan: BatchPlan?
    @Published private(set) var activeIntent: BatchIntent?
    @Published private(set) var runningItem: BatchItem?
    @Published private(set) var result: BatchExecutionResult?
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
        let operationID = operationStore.begin()
        defer { operationStore.end(operationID) }
        let plan = try await operationStore.performCancellable(operationID: operationID) {
            var plans: [BatchProviderPlan] = []
            for item in intent.items {
                try Task.checkCancellation()
                switch item {
                case .homebrew(let identity):
                    let plan = try await self.provider.planHomebrew(identity, operation: intent.operation)
                    guard plan.targets == [identity], plan.canExecute,
                          plan.action == intent.operation.homebrewAction(for: identity.kind)
                    else { throw BatchOperationError.invalidPlan }
                    plans.append(.homebrew(plan))
                case .npm(let identity):
                    let plan = try await self.provider.planNPM(identity, operation: intent.operation)
                    guard plan.request == NodeActionRequest(action: intent.operation.nodeAction, subject: identity.name),
                          plan.canExecute
                    else { throw BatchOperationError.invalidPlan }
                    plans.append(.npm(plan, identity.environment))
                }
            }
            try Task.checkCancellation()
            return BatchPlan(id: UUID(), intent: intent, plans: plans)
        }
        preparedPlan = plan
        return plan
    }

    func execute(_ plan: BatchPlan) async throws -> BatchExecutionResult {
        guard !operationStore.hasActiveOperations else { throw BatchOperationError.busy }
        guard preparedPlan?.id == plan.id else { throw BatchOperationError.planUnavailable }
        preparedPlan = nil
        result = nil
        activeIntent = plan.intent
        let operationID = operationStore.begin()
        defer {
            runningItem = nil
            activeIntent = nil
            operationStore.end(operationID)
        }
        let (outcomes, providerResults, started) = try await operationStore.performCancellable(operationID: operationID) {
            var outcomes: [BatchItemOutcome] = []
            var results: [BatchProviderResult?] = []
            var started = false
            for (item, prepared) in zip(plan.intent.items, plan.plans) {
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
                        status = result.status == "ok" && result.exitCode == 0 ? .succeeded : .failed
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
        runningItem = nil
        let refreshedState: BatchRefreshedState?
        let refreshStatus: BatchRefreshStatus
        if started {
            // Reconciliation must finish even when the caller or provider worker was cancelled.
            let refresh = Task { try await self.refresh(plan.intent.scope) }
            do {
                refreshedState = try await refresh.value
                refreshStatus = .succeeded
            } catch {
                refreshedState = nil
                refreshStatus = .failed
            }
        } else {
            refreshedState = nil
            refreshStatus = .notNeeded
        }
        guard let outcome = BatchOutcome(intent: plan.intent, itemOutcomes: outcomes) else {
            preconditionFailure("The coordinator must retain exactly one ordered outcome per item")
        }
        let result = BatchExecutionResult(outcome: outcome, providerResults: providerResults,
                                          refreshStatus: refreshStatus, refreshedState: refreshedState)
        self.result = result
        activityStore?.append(outcome.activitySummary)
        if refreshStatus == .failed {
            activityStore?.append(ActivitySummary(id: UUID(), operation: .refresh, scope: plan.intent.scope.activityScope,
                                                 targetDisplayNames: [], date: Date(), status: .failed, itemOutcomes: []))
        }
        return result
    }

    private func refresh(_ scope: BatchScope) async throws -> BatchRefreshedState {
        switch scope {
        case .homebrew: .homebrew(try await provider.refreshHomebrew())
        case .npm(let environment): .npm(try await provider.refreshNPM(environment))
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
        }
    }
}

private extension BatchItem {
    var displayIdentifier: String {
        switch self {
        case .homebrew(let identity): identity.name
        case .npm(let identity): identity.name
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
