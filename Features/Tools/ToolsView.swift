import SwiftUI

struct ToolsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Group {
            switch model.selectedToolsCategory {
            case .runtime: RuntimeToolsView(model: model)
                .modifier(ProviderTaskPresentation(model: model, surface: .tools))
            case .terminal: TerminalSettingsView(model: model)
            case .homebrewSources: HomebrewSourcesView(model: model)
            case .npmSources: NPMRegistrySettingsView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .labeledContentStyle(ToolsLabeledContentStyle())
    }
}

private struct ToolsLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            configuration.label
            Spacer(minLength: 0)
            configuration.content
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(minHeight: AppLayout.minimumInfoRowHeight)
    }
}
