import SwiftUI

struct ToolsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Group {
            switch model.selectedToolsCategory {
            case .environment: EnvironmentSetupView(model: model)
            case .runtime: RuntimeToolsView(model: model)
            case .project: ProjectToolsView(model: model)
            case .diagnostics: DiagnosticsToolsView(model: model)
            case .maintenance: MaintenanceToolsView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .controlSize(.regular)
        .modifier(ProviderTaskPresentation(model: model, surface: .tools))
    }
}
