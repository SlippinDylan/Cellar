import Combine
import Foundation

@MainActor
final class OperationStore: ObservableObject {
    static let shared = OperationStore()

    @Published private var activeOperationIDs: Set<UUID> = []
    @Published private(set) var activeTask: ActiveTaskState?
    private var cancelTask: (() -> Void)?

    var activeOperationCount: Int { activeOperationIDs.count }
    var hasActiveOperations: Bool { !activeOperationIDs.isEmpty }

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
        cancelTask?()
    }

    @discardableResult
    func begin() -> UUID {
        let identifier = UUID()
        activeOperationIDs.insert(identifier)
        return identifier
    }

    func end(_ identifier: UUID) {
        precondition(
            activeOperationIDs.remove(identifier) != nil,
            "Every completed operation must have been started"
        )
    }
}

struct ActiveTaskState: Equatable, Sendable {
    let id: UUID
    let cancellationRequested: Bool
    var canCancel: Bool { !cancellationRequested }
}
