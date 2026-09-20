import SwiftUI

struct NodeMaintenancePage: View {
    @ObservedObject var model: AppModel

    private let actions: [(target: String, title: String, detail: String, icon: String, tint: Color)] = [
        ("npm-cache-verify", "校验 npm cache", "只读校验，不删除 cache。", "checkmark.shield", .blue),
        ("npm-cache-clean", "清理 npm cache", "删除 npm 管理的 cache 内容。", "trash", .orange),
        ("node-gyp-cache", "清理 node-gyp cache", "仅处理计划中经过安全解析的用户 cache 目录。", "hammer", .orange),
        ("orphan-bins", "清理孤立命令链接", "仅删除执行前复验仍为孤立状态的符号链接。", "link.badge.plus", .orange),
        ("nvm-old-versions", "删除无用户包的旧 Node", "保留当前和默认版本，只处理没有用户全局包的版本。", "shippingbox.and.arrow.backward", .red),
        ("logs", "整理 Manager 日志", "保留最近 100 个日志文件。", "doc.text.magnifyingglass", .orange)
    ]

    var body: some View {
        NodePageContainer(model: model) { node in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let status = node.managerStatus {
                        GroupBox("Manager") {
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                                NodeValueRow(label: "Runtime", value: status.runtimeDir)
                                NodeValueRow(label: "Logs", value: status.logDir)
                                NodeValueRow(label: "Temporary", value: status.tmpDir)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                    }
                    if let error = node.maintenanceError {
                        GroupBox {
                            Label("维护状态读取失败：\(error)", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    GroupBox("维护操作") {
                        VStack(spacing: 0) {
                            ForEach(Array(actions.enumerated()), id: \.element.target) { index, item in
                                OperationRow(
                                    title: item.title,
                                    detail: item.detail,
                                    systemImage: item.icon,
                                    tint: item.tint,
                                    actionTitle: item.target == "npm-cache-verify" ? "运行" : "准备计划",
                                    role: item.target == "npm-cache-verify" ? nil : .destructive,
                                    isEnabled: !model.isBusy
                                ) {
                                        let value = item.target == "logs" ? "100" : nil
                                        Task { await model.prepareNodeAction(.init(action: .cleanup, subject: item.target, value: value)) }
                                }
                                if index < actions.count - 1 { Divider() }
                            }
                        }
                    }
                    GroupBox("最近日志") {
                        if node.logs.isEmpty {
                            Text("当前没有 Manager 日志").foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(node.logs, id: \.self) { path in
                                    Text(path).font(.callout.monospaced()).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
    }
}
