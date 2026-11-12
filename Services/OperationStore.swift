import Combine
import Foundation

@MainActor
final class OperationStore: ObservableObject {
    static let shared = OperationStore()

    @Published private var activeOperationIDs: Set<UUID> = []
    @Published private(set) var currentOperation: ActiveOperationState?
    private var runningTaskID: UUID?
    var logStore: FileLogStore?

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
        precondition(activeOperationIDs.contains(operationID) && runningTaskID == nil)
        let task = Task { try await operation() }
        runningTaskID = operationID
        defer { runningTaskID = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func updateProgress(completed: Int, total: Int) {
        precondition(completed >= 0 && completed <= total && total > 0)
        guard var currentOperation else { preconditionFailure("Progress requires a registered operation") }
        currentOperation.completed = completed
        currentOperation.total = total
        self.currentOperation = currentOperation
        logStore?.record(level: .debug, category: "operation", message: "\(currentOperation.context.operation.rawValue) processed \(completed)/\(total)", taskID: currentOperation.id)
    }

    func updateContext(_ context: ActiveOperationContext) {
        guard var currentOperation else { preconditionFailure("Context requires a registered operation") }
        currentOperation.context = context
        self.currentOperation = currentOperation
        logStore?.record(level: .debug, category: "operation", message: "\(currentOperation.context.operation.rawValue): \(currentOperation.context.stage)", taskID: currentOperation.id)
    }

    @discardableResult
    func begin(context: ActiveOperationContext = .init(operation: .refresh, scope: nil, targets: [], stage: .checking)) -> UUID {
        let identifier = UUID()
        activeOperationIDs.insert(identifier)
        logStore?.record(level: .info, category: "operation", message: "\(context.operation.rawValue) started", taskID: identifier)
        if currentOperation == nil { currentOperation = .init(id: identifier, context: context) }
        return identifier
    }

    func end(_ identifier: UUID) {
        precondition(
            activeOperationIDs.remove(identifier) != nil,
            "Every completed operation must have been started"
        )
        logStore?.record(level: .debug, category: "operation", message: "Task released", taskID: identifier)
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
}
