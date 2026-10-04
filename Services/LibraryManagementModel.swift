import Combine
import Foundation

@MainActor
final class LibraryManagementModel: ObservableObject {
    @Published private(set) var confirmation: BatchPlan?
    @Published private(set) var result: BatchExecutionResult?
    @Published private(set) var error: LibraryManagementError?
    let model: AppModel

    init(model: AppModel) { self.model = model }

    func prepare(_ selection: [BatchItem]) async {
        guard !model.isBusy else { return }
        confirmation = nil
        result = nil
        error = nil
        guard let intent = LibraryCatalog.uninstallIntent(selection) else {
            error = .invalidSelection
            return
        }
        do { confirmation = try await model.prepareBatch(intent) }
        catch BatchOperationError.protectedNode { self.error = .protectedTarget }
        catch BridgeError.managerFailure(let code, _) where ["protected-package", "cannot-uninstall-current-node", "cannot-uninstall-default-node"].contains(code) {
            self.error = .protectedTarget
        }
        catch { self.error = .preparationFailed }
    }

    func dismissConfirmation() { confirmation = nil }

    func confirmUninstall() async {
        guard let confirmation else { return }
        self.confirmation = nil
        do { result = try await model.executeBatch(confirmation) }
        catch { self.error = .executionRefused }
    }
}

enum LibraryManagementError: Equatable {
    case invalidSelection, protectedTarget, preparationFailed, executionRefused
}
