import SwiftUI

struct NodePackagesPage: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var packageSpec = ""
    @State private var selection: String?
    @State private var showingInstall = false

    var body: some View {
        NodePageContainer(model: model) { node in
            VStack(alignment: .leading, spacing: 10) {
                Text("当前 Node \(node.summary.nodeVersion) · \(node.packages.count) 个顶层全局包")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Table(filteredPackages(node), selection: $selection) {
                    TableColumn("包名", value: \.name)
                    TableColumn("当前版本", value: \.installedVersion)
                    TableColumn("Wanted") { Text($0.wantedVersion ?? "—") }
                    TableColumn("Latest") { Text($0.latestVersion ?? "—") }
                }
                .searchable(text: $query, prompt: "搜索全局包")
            }
            .padding(24)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingInstall = true
                    } label: {
                        Label("安装全局包", systemImage: "plus")
                    }
                    .help("安装 npm 全局包")
                    .disabled(model.isBusy)
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        guard let selectedPackage else { return }
                        Task { await model.prepareNodeAction(.init(action: .updatePackage, subject: selectedPackage.name)) }
                    } label: {
                        Label("更新到 Latest", systemImage: "arrow.up.circle")
                    }
                    .help("将所选包更新到 Latest")
                    .disabled(selectedPackage?.isOutdated != true || model.isBusy)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        guard let selectedPackage else { return }
                        Task { await model.prepareNodeAction(.init(action: .uninstallPackage, subject: selectedPackage.name)) }
                    } label: {
                        Label("卸载", systemImage: "trash")
                    }
                    .help("卸载所选全局包")
                    .disabled(selectedPackage == nil || model.isBusy)
                }
            }
            .sheet(isPresented: $showingInstall) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("安装 npm 全局包").font(.title2.bold())
                    TextField("包名、版本或 tag", text: $packageSpec, prompt: Text("typescript@latest"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(prepareInstall)
                    Text("安装目标属于当前 Cellar 会话选择的 Node 环境。下一步会先生成计划，不会立即执行 npm install。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("取消", role: .cancel) { showingInstall = false }
                            .keyboardShortcut(.cancelAction)
                        Button("继续") { prepareInstall() }
                            .buttonStyle(.glassProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(packageSpec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
                    }
                }
                .padding(24)
                .frame(width: 480)
            }
        }
    }

    private var selectedPackage: NodePackageRow? {
        guard let selection else { return nil }
        return model.node?.packages.first { $0.id == selection }
    }

    private func filteredPackages(_ node: NodeSnapshot) -> [NodePackageRow] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return node.packages }
        return node.packages.filter { $0.name.localizedCaseInsensitiveContains(term) }
    }

    private func prepareInstall() {
        let spec = packageSpec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spec.isEmpty else { return }
        showingInstall = false
        Task { await model.prepareNodeAction(.init(action: .installPackage, subject: spec)) }
    }
}
