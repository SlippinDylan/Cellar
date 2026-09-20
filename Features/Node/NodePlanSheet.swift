import SwiftUI

struct NodePlanSheet: View {
    @ObservedObject var model: AppModel
    let plan: NodeActionPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(plan.request.action.title, systemImage: plan.request.action.isDestructive ? "exclamationmark.triangle" : "shippingbox")
                .font(.title2.bold())
            GroupBox("操作计划") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    NodeValueRow(label: "动作", value: plan.request.action.rawValue)
                    NodeValueRow(label: "目标", value: plan.displayTarget)
                    if let installed = plan.payload.installedVersion, !installed.isEmpty {
                        NodeValueRow(label: "当前版本", value: installed)
                    }
                    if let target = plan.payload.targetVersion, !target.isEmpty {
                        NodeValueRow(label: "目标版本", value: target)
                    }
                    if let value = plan.payload.value, !value.isEmpty { NodeValueRow(label: "值", value: value) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            if let paths = plan.payload.paths, !paths.isEmpty {
                GroupBox("影响路径") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(paths, id: \.self) { Text($0).font(.callout.monospaced()).textSelection(.enabled) }
                    }
                }
            }
            if let blockedReason = plan.payload.blockedReason, !blockedReason.isEmpty {
                Label("计划已阻止：\(blockedReason)", systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            Text(disclosure).font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { model.dismissNodePlan() }.keyboardShortcut(.cancelAction)
                Button(role: plan.request.action.isDestructive ? .destructive : nil) {
                    Task { await model.executeNodePlan() }
                } label: { Text("确认并执行") }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                .disabled(!plan.canExecute || model.isNodeWorking)
            }
        }
        .padding(24).frame(width: 620)
    }

    private var disclosure: String {
        switch plan.request.action {
        case .useNode: "只改变 Cellar 本次会话后续命令使用的受控 Node，不改变终端环境。"
        case .writeProjectNVMRC: "只写入计划列出的项目 .nvmrc；不会修改其他项目或 nvm 默认版本。"
        case .cleanup: "执行前会重新校验计划 token 和候选状态；不会扩大到计划之外的路径。"
        default: "命令可能访问 npm、Node 或 nvm 的网络服务并修改当前受控环境；完成后 Cellar 会重新读取真实状态。"
        }
    }
}

struct NodeResultSheet: View {
    @ObservedObject var model: AppModel
    let result: NodeActionResult

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(
                result.operation.status == "ok" ? "操作完成" : "操作需要检查",
                systemImage: result.operation.status == "ok" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.title2.bold()).foregroundStyle(result.operation.status == "ok" ? .green : .orange)
            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    NodeValueRow(label: "动作", value: result.operation.action)
                    NodeValueRow(label: "目标", value: result.operation.subject)
                    NodeValueRow(label: "状态", value: result.operation.status)
                    NodeValueRow(label: "退出状态", value: "\(result.operation.exitCode)")
                    NodeValueRow(label: "日志", value: result.operation.logFile)
                    if let error = result.postflightError { NodeValueRow(label: "复查错误", value: error) }
                }
                .textSelection(.enabled)
            }
            if let residues = result.operation.residues, !residues.directories.isEmpty || !residues.bins.isEmpty {
                GroupBox("仍存在的残留") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(residues.directories + residues.bins, id: \.self) {
                            Text($0).font(.callout.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
            HStack { Spacer(); Button("关闭") { model.dismissNodeFeedback() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 620)
    }
}
