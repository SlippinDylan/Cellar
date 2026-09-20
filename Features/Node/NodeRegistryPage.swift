import SwiftUI

struct NodeRegistryPage: View {
    @ObservedObject var model: AppModel
    @State private var editingDefault = false
    @State private var editingScope = false

    var body: some View {
        NodePageContainer(model: model) { node in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    StatusOverviewCard {
                        StatusMetric(
                            title: "当前生效 Registry",
                            value: node.configuration.registry,
                            detail: registrySource(node),
                            systemImage: "globe",
                            tint: .blue
                        )
                    }

                    GroupBox("配置层") {
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                            NodeValueRow(label: "User", value: display(node.configuration.userRegistry))
                            NodeValueRow(label: "Project", value: display(node.configuration.projectRegistry))
                            NodeValueRow(label: "Global", value: display(node.configuration.globalRegistry))
                            Divider()
                            NodeValueRow(label: "Cache", value: node.configuration.cache)
                            NodeValueRow(label: "Prefix", value: node.configuration.prefix)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                    }

                    GroupBox("受控修改") {
                        VStack(spacing: 0) {
                            OperationRow(
                                title: "默认 Registry",
                                detail: "设置或删除用户级 registry；执行前展示计划。",
                                systemImage: "network",
                                tint: .blue,
                                actionTitle: "管理…",
                                isEnabled: !model.isBusy
                            ) { editingDefault = true }

                            Divider()

                            OperationRow(
                                title: "Scope Registry",
                                detail: "为明确的 @scope 设置或删除 registry。",
                                systemImage: "at",
                                tint: .purple,
                                actionTitle: "管理…",
                                isEnabled: !model.isBusy
                            ) { editingScope = true }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .sheet(isPresented: $editingDefault) {
                DefaultRegistrySheet(model: model)
            }
            .sheet(isPresented: $editingScope) {
                ScopeRegistrySheet(model: model)
            }
        }
    }

    private func display(_ value: String?) -> String {
        guard let value, !value.isEmpty, value != "undefined" else { return "未设置" }
        return value
    }

    private func registrySource(_ node: NodeSnapshot) -> String {
        if display(node.configuration.projectRegistry) != "未设置" { return "来自项目配置" }
        if display(node.configuration.userRegistry) != "未设置" { return "来自用户配置" }
        if display(node.configuration.globalRegistry) != "未设置" { return "来自全局配置" }
        return "npm 默认值"
    }
}

private struct DefaultRegistrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @State private var registry = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("默认 Registry", systemImage: "network")
                .font(.title2.weight(.semibold))
            TextField("https://registry.example.com/", text: $registry)
                .textFieldStyle(.roundedBorder)
                .onSubmit(prepareSet)
            Text("修改的是用户级 npm registry。项目配置仍可以覆盖它。")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("删除用户配置", role: .destructive) {
                    dismiss()
                    Task { await model.prepareNodeAction(.init(action: .deleteRegistry)) }
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("生成设置计划") { prepareSet() }
                    .buttonStyle(.glassProminent)
                    .disabled(trimmedRegistry.isEmpty || model.isBusy)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var trimmedRegistry: String {
        registry.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func prepareSet() {
        guard !trimmedRegistry.isEmpty else { return }
        dismiss()
        Task { await model.prepareNodeAction(.init(action: .setRegistry, subject: trimmedRegistry)) }
    }
}

private struct ScopeRegistrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @State private var scope = ""
    @State private var registry = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Scope Registry", systemImage: "at")
                .font(.title2.weight(.semibold))
            TextField("@scope", text: $scope)
                .textFieldStyle(.roundedBorder)
            TextField("https://registry.example.com/", text: $registry)
                .textFieldStyle(.roundedBorder)
            Text("只处理明确 scope；生成计划时 Manager 会再次校验输入。")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("生成删除计划", role: .destructive) {
                    guard !trimmedScope.isEmpty else { return }
                    dismiss()
                    Task { await model.prepareNodeAction(.init(action: .deleteScopeRegistry, subject: trimmedScope)) }
                }
                .disabled(trimmedScope.isEmpty || model.isBusy)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("生成设置计划") {
                    guard !trimmedScope.isEmpty, !trimmedRegistry.isEmpty else { return }
                    dismiss()
                    Task {
                        await model.prepareNodeAction(.init(
                            action: .setScopeRegistry,
                            subject: trimmedScope,
                            value: trimmedRegistry
                        ))
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(trimmedScope.isEmpty || trimmedRegistry.isEmpty || model.isBusy)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var trimmedScope: String { scope.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedRegistry: String { registry.trimmingCharacters(in: .whitespacesAndNewlines) }
}
