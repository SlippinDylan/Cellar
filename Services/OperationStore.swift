import Combine
import Foundation

@MainActor
final class OperationStore: ObservableObject {
    static let shared = OperationStore()

    @Published private var activeOperationIDs: Set<UUID> = []

    var activeOperationCount: Int { activeOperationIDs.count }
    var hasActiveOperations: Bool { !activeOperationIDs.isEmpty }

    private init() {}

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
