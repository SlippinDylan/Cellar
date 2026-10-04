import SwiftUI

struct AppCommands: Commands {
    @FocusedValue(\.libraryActions) private var libraryActions
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
            Button("Find in Library") { libraryActions?.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model.selectedDestination != .library || libraryActions == nil)
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
