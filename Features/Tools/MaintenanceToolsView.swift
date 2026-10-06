import SwiftUI

struct MaintenanceToolsView: View {
    @ObservedObject var model: AppModel
    @State private var showsDiagnostics = false
    var body: some View {
        Form {
            Section {
                Text("Refresh Homebrew and Tap metadata. Installed software is not upgraded.").foregroundStyle(.secondary)
                Button("Update Homebrew Metadata") {
                    Task { await model.performHomebrewMetadataUpdate() }
                }.disabled(model.homebrew?.isInstalled != true || model.isBusy)
            } header: { Text("Homebrew Metadata") }
            Section {
                if let node = model.node {
                    Text("Node Environment: \(node.summary.nodeVersion) · npm \(node.summary.npmVersion)")
                    if let error = node.maintenanceError {
                        Label("Some maintenance information could not be read.", systemImage: "exclamationmark.triangle")
                        Button("Session Diagnostics…") {
                            model.activityDiagnostics.record(operation: .maintenance, scope: node.summary.activityEnvironment.map(ActivityScope.npm), detail: error)
                            showsDiagnostics = true
                        }
                    }
                } else { Text("Node Environment Unavailable") }
                ForEach(NodeMaintenanceAction.allCases) { action in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(action.detail).foregroundStyle(.secondary)
                        Button {
                            Task {
                                if action == .verify { await model.performDirectNodeAction(action.request) }
                                else { await model.prepareNodeAction(action.request) }
                            }
                        } label: { Text(action.title) }
                            .disabled(model.node == nil || model.isBusy)
                    }
                }
            } header: { Text("Node Maintenance") }
            Section {
                Text("Move the listed Zsh completion files and historical backups into .zsh. Back up .zshrc before updating its managed completion location.").foregroundStyle(.secondary)
                Button("Tidy Zsh Files…") { Task { await model.prepareShellAction(.init(action: .tidy, subject: "zsh-files")) } }
                    .disabled(model.shell?.zshrcExists != true || model.isBusy)
            } header: { Text("Zsh Files") }
        }.formStyle(AppFormStyle())
        .sheet(isPresented: $showsDiagnostics) {
            ActivityDiagnosticsView(store: model.activityDiagnostics, initialSelection: nil, clipboard: .live)
        }
    }
}
