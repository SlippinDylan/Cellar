import SwiftUI

struct AppRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var operationStore: OperationStore
    private let updateController: ApplicationUpdateController
    @Environment(\.openWindow) private var openWindow

    init(model: AppModel, updateController: ApplicationUpdateController) {
        self.model = model
        self.updateController = updateController
        operationStore = model.operationStore
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(AppDestination.primaryDestinations, selection: sidebarSelection(for: AppDestination.primaryDestinations)) { destination in
                    destinationLabel(destination)
                        .tag(destination)
                }
                .listStyle(.sidebar)

                // Activity is navigation; critical task controls stay in the toolbar and menu.
                List(selection: sidebarSelection(for: AppDestination.bottomDestinations)) {
                    destinationLabel(.settings)
                        .tag(AppDestination.settings)
                    destinationLabel(.activity)
                        .tag(AppDestination.activity)
                }
                .listStyle(.sidebar)
                .scrollDisabled(true)
                .frame(height: 104)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            destinationContent
                .navigationTitle(Text(model.selectedDestination.title))
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await model.performShellAction(.refresh) }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .help("Refresh Local Environment (⌘R)")
                        .disabled(model.isBusy)
                    }
                    if model.isBusy {
                        ToolbarItem(placement: .status) {
                            Button {
                                model.showActivity { openWindow(id: $0, value: $1) }
                            } label: {
                                HStack {
                                    ProgressView().controlSize(.small)
                                    Text("View Activity")
                                }
                            }
                            .help("View Activity")
                        }
                    }
                    if let task = operationStore.activeTask {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                Task { await model.performShellAction(.cancel) }
                            } label: {
                                Label("Cancel Task", systemImage: "stop")
                            }
                            .help("Cancel Task")
                            .disabled(!task.canCancel)
                        }
                    }
                }
        }
        .navigationSplitViewStyle(.prominentDetail)
        .task { await model.refreshOnLaunch() }
    }

    @ViewBuilder private var destinationContent: some View {
        if model.selectedDestination == .home { HomeView(model: model) }
        else if model.selectedDestination == .library { LibraryView(model: model) }
        else if model.selectedDestination == .discover { DiscoverView(model: model) }
        else if model.selectedDestination == .updates { UpdatesView(model: model) }
        else if model.selectedDestination == .tools { ToolsView(model: model) }
        else if model.selectedDestination == .settings { SettingsView(model: model, updateController: updateController, relaunchController: .shared) }
        else if model.selectedDestination == .activity { ActivityView(model: model) }
        else { ShellPlaceholderView(destination: model.selectedDestination) }
    }

    func sidebarSelection(for destinations: [AppDestination]) -> Binding<AppDestination?> {
        // Each native List must own its selection, while navigation has one source of truth.
        Binding(get: { destinations.contains(model.selectedDestination) ? model.selectedDestination : nil }, set: { destination in
            if let destination, destinations.contains(destination) { model.selectedDestination = destination }
        })
    }

    private func destinationLabel(_ destination: AppDestination) -> some View {
        Label { Text(destination.title) } icon: { Image(systemName: destination.systemImage) }
    }
}
