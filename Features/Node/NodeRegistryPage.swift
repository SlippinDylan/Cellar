import SwiftUI

struct NodeRegistryPage: View {
    @ObservedObject var model: AppModel
    @State private var registry = ""
    @State private var scope = ""
    @State private var scopeRegistry = ""

    var body: some View {
        NodePageContainer(model: model) { node in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("有效配置") {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                            NodeValueRow(label: "Effective", value: node.configuration.registry)
                            NodeValueRow(label: "User", value: node.configuration.userRegistry)
                            NodeValueRow(label: "Project", value: node.configuration.projectRegistry)
                            NodeValueRow(label: "Global", value: node.configuration.globalRegistry)
                            NodeValueRow(label: "Cache", value: node.configuration.cache)
                            NodeValueRow(label: "Prefix", value: node.configuration.prefix)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    GroupBox("默认 Registry") {
                        HStack {
                            TextField("https://registry.example.com/", text: $registry).textFieldStyle(.roundedBorder)
                            Button("准备设置") {
                                Task { await model.prepareNodeAction(.init(action: .setRegistry, subject: registry)) }
                            }
                            .buttonStyle(.glassProminent).disabled(registry.isEmpty || model.isBusy)
                            Button("删除用户配置", role: .destructive) {
                                Task { await model.prepareNodeAction(.init(action: .deleteRegistry)) }
                            }
                            .disabled(model.isBusy)
                        }
                    }
                    GroupBox("Scope Registry") {
                        VStack(spacing: 10) {
                            HStack {
                                TextField("@scope", text: $scope).textFieldStyle(.roundedBorder)
                                TextField("https://registry.example.com/", text: $scopeRegistry).textFieldStyle(.roundedBorder)
                            }
                            HStack {
                                Spacer()
                                Button("准备删除", role: .destructive) {
                                    Task { await model.prepareNodeAction(.init(action: .deleteScopeRegistry, subject: scope)) }
                                }
                                .disabled(scope.isEmpty || model.isBusy)
                                Button("准备设置") {
                                    Task { await model.prepareNodeAction(.init(action: .setScopeRegistry, subject: scope, value: scopeRegistry)) }
                                }
                                .buttonStyle(.glassProminent)
                                .disabled(scope.isEmpty || scopeRegistry.isEmpty || model.isBusy)
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
    }
}
