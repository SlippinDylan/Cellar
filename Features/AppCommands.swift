import SwiftUI

struct AppCommands: Commands {
    @FocusedValue(\.catalogSearchAction) private var catalogSearchAction
    @FocusedValue(\.batchInstallAction) private var batchInstallAction
    @FocusedValue(\.packageUpdateActions) private var packageUpdateActions
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel
    @ObservedObject var updateController: ApplicationUpdateController
    @ObservedObject var onboardingState: OnboardingState

    init(model: AppModel, updateController: ApplicationUpdateController, onboardingState: OnboardingState) {
        self.model = model
        self.updateController = updateController
        self.onboardingState = onboardingState
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .appInfo) {
            Button("About Cellar") {
                model.showDestination(.about) { openWindow(id: $0, value: $1) }
            }
            .disabled(!onboardingState.isCompleted)
        }
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updateController.checkForUpdates() }
                .disabled(!updateController.canCheckForUpdates)
            Button("Setup Guide…") { openWindow(id: AppScene.onboardingWindowID) }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.showDestination(.settings) { openWindow(id: $0, value: $1) } }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(!onboardingState.isCompleted)
        }
        CommandMenu("Go") {
            ForEach(AppDestination.allCases) { destination in
                Button {
                    model.showDestination(destination) { openWindow(id: $0, value: $1) }
                } label: { Text(destination.title) }
                    .disabled(!onboardingState.isCompleted)
            }
        }
        CommandGroup(after: .toolbar) {
            Button("Find") { catalogSearchAction?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(catalogSearchAction == nil)
            Button("Batch Install") { batchInstallAction?() }
                .disabled(model.selectedDestination != .maintenance || batchInstallAction == nil || model.isBusy
                          || (!model.discoverContext.homebrewAvailable && model.discoverContext.npm == nil))
            Button("Update All") { packageUpdateActions?.updateAll() }
                .disabled(model.selectedDestination != .library || packageUpdateActions?.canUpdateAll != true || model.isBusy)
            Button("Check for Package Updates") { packageUpdateActions?.checkUpdates() }
                .disabled(model.selectedDestination != .library || packageUpdateActions == nil || model.isBusy || model.refreshedAt == nil)
            Button("Refresh") { Task { await model.performShellAction(.refresh) } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isBusy)
        }
    }
}
