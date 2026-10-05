import SwiftUI

struct AppCommands: Commands {
    @FocusedValue(\.catalogSearchAction) private var catalogSearchAction
    @FocusedValue(\.discoverBatchAction) private var discoverBatchAction
    @FocusedValue(\.packageUpdateActions) private var packageUpdateActions
    @FocusedValue(\.activityActions) private var activityActions
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel
    let updateController: ApplicationUpdateController

    init(model: AppModel, updateController: ApplicationUpdateController) {
        self.model = model
        self.updateController = updateController
    }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Cellar") {
                model.showSettingsPane(.about) { openWindow(id: $0, value: $1) }
            }
        }
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updateController.checkForUpdates() }
                .disabled(!updateController.canCheckForUpdates)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.showDestination(.settings) { openWindow(id: $0, value: $1) } }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandMenu("Go") {
            ForEach(AppDestination.allCases) { destination in
                Button {
                    model.showDestination(destination) { openWindow(id: $0, value: $1) }
                } label: { Text(destination.title) }
            }
        }
        CommandMenu("Activity") {
            Button("Copy Summary") { activityActions?.copy() }.disabled(activityActions?.canCopy != true)
            Button("Session Diagnostics…") { activityActions?.showDiagnostics() }.disabled(activityActions == nil)
            Menu("Provider") {
                ForEach(ActivityProviderFilter.allCases, id: \.self) { provider in
                    Button(ActivityRenderer().provider(provider)) { activityActions?.setProvider(provider) }
                }
            }.disabled(activityActions == nil)
            Menu("Status") {
                Button("All Statuses") { activityActions?.setStatus(nil) }
                ForEach(ActivityStatus.allCases, id: \.self) { status in Button { activityActions?.setStatus(status) } label: { Text(status.title) } }
            }.disabled(activityActions == nil)
            Button("Clear Activity Filters") { activityActions?.clearFilters() }.disabled(activityActions == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Find") { catalogSearchAction?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(catalogSearchAction == nil)
            Button("Batch Install") { discoverBatchAction?() }
                .disabled(model.selectedDestination != .discover || discoverBatchAction == nil || model.isBusy)
            Button("Update All") { packageUpdateActions?.updateAll() }
                .disabled(model.selectedDestination != .updates || packageUpdateActions?.canUpdateAll != true || model.isBusy)
            Button("Check for Package Updates") { packageUpdateActions?.checkUpdates() }
                .disabled(model.selectedDestination != .updates || packageUpdateActions == nil || model.isBusy || model.refreshedAt == nil)
            Button("Refresh") { Task { await model.performShellAction(.refresh) } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isBusy)
            Button("View Activity") { model.showActivity { openWindow(id: $0, value: $1) } }
        }
    }
}
