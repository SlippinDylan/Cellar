import SwiftUI

struct NodeMaintenanceView: View {
    @ObservedObject var model: AppModel
    @State private var showsDiagnostics = false

    var body: some View {
        SettingsSection(title: "Node Maintenance") {
            VStack(alignment: .leading, spacing: 0) {
                if let node = model.node, let error = node.maintenanceError {
                    Label("Some maintenance information could not be read.", systemImage: "exclamationmark.triangle")
                    Button("Session Diagnostics…") {
                        model.activityDiagnostics.record(operation: .maintenance, scope: node.summary.activityEnvironment.map(ActivityScope.npm), detail: error)
                        showsDiagnostics = true
                    }.padding(.bottom, 12)
                }
                ForEach(NodeMaintenanceAction.allCases) { action in
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(action.title).fontWeight(.medium)
                            Text(action.detail).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button {
                            Task {
                                if action == .verify { await model.performDirectNodeAction(action.request) }
                                else { await model.prepareNodeAction(action.request) }
                            }
                        } label: { Text(action.title) }
                            .disabled(model.node == nil || model.isBusy)
                            .fixedSize()
                    }.frame(minHeight: AppLayout.minimumDescribedRowHeight)
                    if action != NodeMaintenanceAction.allCases.last { Divider() }
                }
            }
        }
        .sheet(isPresented: $showsDiagnostics) {
            ActivityDiagnosticsView(store: model.activityDiagnostics, initialSelection: nil, clipboard: .live)
        }
    }
}
