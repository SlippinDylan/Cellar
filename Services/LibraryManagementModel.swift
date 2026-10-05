import Combine
import Foundation

@MainActor
final class LibraryUninstallModel: ObservableObject {
    @Published private(set) var confirmation: BatchPlan?
    @Published private(set) var result: BatchExecutionResult?
    @Published private(set) var error: LibraryUninstallError?
    @Published private(set) var failureReason: ActivityItemReason?
    let model: AppModel

    init(model: AppModel) { self.model = model }

    func prepare(_ item: BatchItem) async {
        guard !model.isBusy else { return }
        confirmation = nil
        result = nil
        error = nil
        failureReason = nil
        guard let intent = LibraryCatalog.uninstallIntent(item) else {
            error = .invalidTarget
            return
        }
        do { confirmation = try await model.prepareBatch(intent) }
        catch BatchOperationError.protectedNode { self.error = .protectedTarget }
        catch BridgeError.managerFailure(let code, _) where ["protected-package", "cannot-uninstall-current-node", "cannot-uninstall-default-node"].contains(code) {
            self.error = .protectedTarget
        }
        catch { self.error = .preparationFailed; failureReason = .init(error: error, preparing: true); _ = model.failureMessage(error, preparing: true) }
    }

    func dismissConfirmation() { confirmation = nil }

    func confirmUninstall() async {
        guard let confirmation else { return }
        self.confirmation = nil
        do { result = try await model.executeBatch(confirmation) }
        catch { self.error = .executionRefused; failureReason = .init(error: error); _ = model.failureMessage(error) }
    }
}

enum LibraryUninstallError: Equatable {
    case invalidTarget, protectedTarget, preparationFailed, executionRefused
}
