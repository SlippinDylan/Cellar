import SwiftUI
import UniformTypeIdentifiers

struct NodeVersionsPage: View {
    @ObservedObject var model: AppModel
    @State private var installTarget = "lts"
    @State private var selection: String?
    @State private var projectDirectory: URL?
    @State private var projectVersion = ""
    @State private var choosingProject = false
    @State private var showingInstall = false

    var body: some View {
        NodePageContainer(model: model) { node in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    installedVersionsSection(node)
                    projectSection
                }
                .padding(24)
            }
            .fileImporter(isPresented: $choosingProject, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result { projectDirectory = urls.first }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingInstall = true } label: {
                        Label("安装 Node", systemImage: "plus")
                    }
                    .help("安装 Node 版本")
                    .disabled(model.isBusy)
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("用于本次 Cellar 会话") { prepareVersionAction(.useNode) }
                        Button("设为默认 Node") { prepareVersionAction(.setDefaultNode) }
                        Divider()
                        Button("卸载 Node", role: .destructive) { prepareVersionAction(.uninstallNode) }
                    } label: {
                        Label("版本操作", systemImage: "ellipsis.circle")
                    }
                    .help("管理所选 Node 版本")
                    .disabled(selection == nil || model.isBusy)
                }
            }
            .sheet(isPresented: $showingInstall) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("安装 Node").font(.title2.bold())
                    TextField("版本、lts 或 lts/<line>", text: $installTarget)
                        .textFieldStyle(.roundedBorder)
                    Text("安装由 nvm 执行。下一步只生成操作计划，确认后才会访问网络和写入 ~/.nvm。")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("安装 nvm…") {
                            showingInstall = false
                            Task { await model.prepareNodeAction(.init(action: .installNVM)) }
                        }
                        .disabled(node.summary.nvmLoaded || model.isBusy)
                        Spacer()
                        Button("取消", role: .cancel) { showingInstall = false }.keyboardShortcut(.cancelAction)
                        Button("继续") {
                            let value = installTarget.trimmingCharacters(in: .whitespacesAndNewlines)
                            showingInstall = false
                            Task { await model.prepareNodeAction(.init(action: .installNode, subject: value)) }
                        }
                        .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                        .disabled(installTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
                    }
                }
                .padding(24).frame(width: 480)
            }
        }
    }

    private func installedVersionsSection(_ node: NodeSnapshot) -> some View {
        GroupBox("已安装版本") {
            VStack(alignment: .leading, spacing: 12) {
                if node.installations.isEmpty {
                    ContentUnavailableView(
                        "尚未发现 nvm Node 版本",
                        systemImage: "shippingbox",
                        description: Text("可以从工具栏生成安装计划。")
                    )
                    .frame(minHeight: 160)
                } else {
                    Table(node.installations, selection: $selection) {
                        TableColumn("版本") { installation in
                            Text(installation.version)
                                .font(.body.monospaced())
                        }
                        TableColumn("Cellar 会话") { installation in
                            if installation.isActive {
                                Label("使用中", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Text("—").foregroundStyle(.tertiary)
                            }
                        }
                        TableColumn("默认") { installation in
                            if installation.isDefault {
                                Label("默认", systemImage: "star.fill")
                                    .foregroundStyle(.orange)
                            } else {
                                Text("—").foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .alternatingRowBackgrounds(.disabled)
                    .frame(minHeight: 180, idealHeight: 240)
                }
                Text("会话切换只改变 Cellar 后续读取使用的受控 PATH，不会改变已经打开的终端。设为默认会修改 ~/.nvm/alias/default。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var projectSection: some View {
        GroupBox("项目 .nvmrc") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(projectDirectory?.path ?? "尚未选择项目目录")
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button("选择项目…") { choosingProject = true }
                }
                HStack {
                    TextField("具体版本，例如 v22.14.0", text: $projectVersion).textFieldStyle(.roundedBorder)
                    Button("准备写入") { prepareProjectNVMRC() }
                        .buttonStyle(.glassProminent)
                        .disabled(projectDirectory == nil || projectVersion.isEmpty || model.isBusy)
                }
                Text("只写入用户明确选择目录中的 .nvmrc；计划会显示现有内容、package.json engines.node 和符号链接阻塞状态。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func prepareVersionAction(_ action: NodeAction) {
        guard let selection else { return }
        Task { await model.prepareNodeAction(.init(action: action, subject: selection)) }
    }

    private func prepareProjectNVMRC() {
        guard let projectDirectory else { return }
        let version = projectVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { return }
        Task {
            await model.prepareNodeAction(.init(action: .writeProjectNVMRC, subject: projectDirectory.path, value: version))
        }
    }
}
