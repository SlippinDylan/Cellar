import SwiftUI

struct AppRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var operationStore: OperationStore

    init(model: AppModel) {
        self.model = model
        operationStore = model.operationStore
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(AppDestination.primaryDestinations, selection: sidebarSelection) { destination in
                    destinationLabel(destination)
                        .tag(destination)
                }
                .listStyle(.sidebar)

                // Activity is navigation; critical task controls stay in the toolbar and menu.
                List(selection: sidebarSelection) {
                    destinationLabel(.activity)
                        .tag(AppDestination.activity)
                }
                .listStyle(.sidebar)
                .scrollDisabled(true)
                .frame(height: 52)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            ShellPlaceholderView(destination: model.selectedDestination)
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
                                Task { await model.performShellAction(.show(.activity)) }
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

    private var sidebarSelection: Binding<AppDestination?> {
        Binding(get: { model.selectedDestination }, set: { destination in
            if let destination { model.selectedDestination = destination }
        })
    }

    private func destinationLabel(_ destination: AppDestination) -> some View {
        Label { Text(destination.title) } icon: { Image(systemName: destination.systemImage) }
    }
}
