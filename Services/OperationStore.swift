import Combine
import Foundation

@MainActor
final class OperationStore: ObservableObject {
    static let shared = OperationStore()

    @Published private var activeOperationIDs: Set<UUID> = []
    @Published private(set) var activeTask: ActiveTaskState?
    @Published private(set) var currentOperation: ActiveOperationState?
    private var cancelTask: (() -> Void)?

    var activeOperationCount: Int { activeOperationIDs.count }
    var hasActiveOperations: Bool { !activeOperationIDs.isEmpty }

    func isSoleOperation(_ identifier: UUID) -> Bool {
        activeOperationIDs == [identifier]
    }

    init() {}

    func performCancellable<Value: Sendable>(
        operationID: UUID,
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        precondition(activeOperationIDs.contains(operationID) && activeTask == nil)
        let task = Task { try await operation() }
        activeTask = ActiveTaskState(id: operationID, cancellationRequested: false)
        cancelTask = { task.cancel() }
        defer {
            cancelTask = nil
            activeTask = nil
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancelActiveTask() {
        guard let activeTask, activeTask.canCancel else { return }
        self.activeTask = ActiveTaskState(id: activeTask.id, cancellationRequested: true)
        currentOperation?.cancellationRequested = true
        cancelTask?()
    }

    func updateProgress(completed: Int, total: Int) {
        precondition(completed >= 0 && completed <= total && total > 0)
        guard var currentOperation else { preconditionFailure("Progress requires a registered operation") }
        currentOperation.completed = completed
        currentOperation.total = total
        self.currentOperation = currentOperation
    }

    func updateContext(_ context: ActiveOperationContext) {
        guard var currentOperation else { preconditionFailure("Context requires a registered operation") }
        currentOperation.context = context
        self.currentOperation = currentOperation
    }

    @discardableResult
    func begin(context: ActiveOperationContext = .init(operation: .refresh, scope: nil, targets: [], stage: .checking)) -> UUID {
        let identifier = UUID()
        activeOperationIDs.insert(identifier)
        if currentOperation == nil { currentOperation = .init(id: identifier, context: context) }
        return identifier
    }

    func end(_ identifier: UUID) {
        precondition(
            activeOperationIDs.remove(identifier) != nil,
            "Every completed operation must have been started"
        )
        if currentOperation?.id == identifier { currentOperation = nil }
    }
}

enum ActivityTaskStage: Equatable, Sendable { case preparing, executing, checking, reconciling }

struct ActiveOperationContext: Equatable, Sendable {
    let operation: ActivityOperationKind
    let scope: ActivityScope?
    let targets: [String]
    let stage: ActivityTaskStage
}

struct ActiveOperationState: Equatable, Sendable {
    let id: UUID
    var context: ActiveOperationContext
    var completed: Int? = nil
    var total: Int? = nil
    var cancellationRequested = false
}

struct ActiveTaskState: Equatable, Sendable {
    let id: UUID
    let cancellationRequested: Bool
    var canCancel: Bool { !cancellationRequested }
}
