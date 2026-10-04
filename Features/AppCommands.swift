import SwiftUI

struct AppCommands: Commands {
    @FocusedValue(\.libraryActions) private var libraryActions
    @FocusedValue(\.catalogSearchAction) private var catalogSearchAction
    @FocusedValue(\.discoverBatchAction) private var discoverBatchAction
    @FocusedValue(\.packageUpdateActions) private var packageUpdateActions
    @ObservedObject var model: AppModel
    @ObservedObject private var operationStore: OperationStore
    let updateController: ApplicationUpdateController

    init(model: AppModel, updateController: ApplicationUpdateController) {
        self.model = model
        operationStore = model.operationStore
        self.updateController = updateController
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updateController.checkForUpdates() }
                .disabled(!updateController.canCheckForUpdates)
        }
        CommandMenu("Go") {
            ForEach(AppDestination.allCases) { destination in
                Button {
                    Task { await model.performShellAction(.show(destination)) }
                } label: { Text(destination.title) }
            }
        }
        CommandGroup(after: .toolbar) {
            Button("Find") { catalogSearchAction?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(catalogSearchAction == nil)
            Button("Batch Install…") { discoverBatchAction?() }
                .disabled(model.selectedDestination != .discover || discoverBatchAction == nil || model.isBusy)
            Button("Update All…") { packageUpdateActions?.updateAll() }
                .disabled(model.selectedDestination != .updates || packageUpdateActions?.canUpdateAll != true || model.isBusy)
            Button("Check for Package Updates") { packageUpdateActions?.checkUpdates() }
                .disabled(model.selectedDestination != .updates || packageUpdateActions == nil || model.isBusy || model.refreshedAt == nil)
            Button { libraryActions?.toggleManage() } label: {
                Text(libraryActions?.isManaging == true ? LocalizedStringResource("Finish Managing Library") : LocalizedStringResource("Manage Library…"))
            }
                .disabled(model.selectedDestination != .library || libraryActions == nil || model.isBusy)
            Button("Refresh") { Task { await model.performShellAction(.refresh) } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isBusy)
            Button("View Activity") { Task { await model.performShellAction(.show(.activity)) } }
            Button("Cancel Task") { Task { await model.performShellAction(.cancel) } }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(operationStore.activeTask?.canCancel != true)
        }
    }
}
