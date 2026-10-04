import SwiftUI

struct ToolsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Tools Category", selection: $model.selectedToolsCategory) {
                ForEach(ToolsCategory.allCases) { category in Text(category.title).tag(category) }
            }
            .pickerStyle(.menu)
            .padding(20)
            Divider()
            switch model.selectedToolsCategory {
            case .environment: EnvironmentSetupView(model: model)
            case .runtime: RuntimeToolsView(model: model)
            case .project: ProjectToolsView(model: model)
            case .diagnostics: DiagnosticsToolsView(model: model)
            case .maintenance: MaintenanceToolsView(model: model)
            }
        }
        .controlSize(.regular)
        .modifier(ProviderTaskPresentation(model: model, surface: .tools))
    }
}
