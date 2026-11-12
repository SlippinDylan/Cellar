import SwiftUI

struct MaintenanceView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsPage(fillsViewport: true) {
            if model.selectedMaintenanceCategory == .checks {
                DiagnosticsToolsView(model: model)
            }
            NodeMaintenanceView(model: model, category: model.selectedMaintenanceCategory)
            Spacer(minLength: 0)
            EnvironmentFooterView {
                if let node = model.node {
                    LabeledContent("Node Version", value: node.summary.nodeVersion)
                    LabeledContent("npm Version", value: node.summary.npmVersion)
                } else {
                    Text("Node Environment Unavailable")
                }
            }
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .modifier(ProviderTaskPresentation(model: model, surface: .maintenance))
    }
}
