import SwiftUI

struct ShellPlanSheet: View {
    @ObservedObject var model: AppModel
    let plan: ShellActionPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(plan.request.action.title, systemImage: plan.request.action.isDestructive ? "exclamationmark.triangle" : "terminal")
                .font(.title2.bold())
            GroupBox("操作计划") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    ShellValueRow(label: "动作", value: plan.request.action.rawValue)
                    ShellValueRow(label: "目标", value: plan.payload.subject)
                    ShellValueRow(label: "路径", value: plan.payload.targetPath)
                }
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            if !plan.payload.blockedReason.isEmpty {
                Label("计划已阻止：\(plan.payload.blockedReason)", systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            Text("执行前会复验 .zshrc、Oh My Zsh 或目标目录状态。配置写入使用带标记的 managed block，并在已有 .zshrc 时先创建备份。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { model.dismissShellPlan() }.keyboardShortcut(.cancelAction)
                Button(role: plan.request.action.isDestructive ? .destructive : nil) {
                    Task { await model.executeShellPlan() }
                } label: { Text("确认并执行") }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                .disabled(!plan.canExecute || model.isBusy)
            }
        }
        .padding(24).frame(width: 620)
    }
}

struct ShellResultSheet: View {
    @ObservedObject var model: AppModel
    let result: ShellActionResult

    var body: some View {
        VStack(spacing: 0) {
            Label(result.operation.status == "ok" ? "操作完成" : "操作需要检查", systemImage: result.operation.status == "ok" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title2.bold())
                .foregroundStyle(result.operation.status == "ok" ? .green : .orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)

            Divider()

            ScrollView {
                GroupBox {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        ShellValueRow(label: "动作", value: result.operation.action)
                        ShellValueRow(label: "目标", value: result.operation.subject)
                        ShellValueRow(label: "日志", value: result.operation.logFile)
                        if !result.operation.backupPath.isEmpty {
                            ShellValueRow(label: ".zshrc 备份", value: result.operation.backupPath)
                        }
                        if let error = result.postflightError {
                            ShellValueRow(label: "复查错误", value: error)
                        }
                    }
                    .textSelection(.enabled)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Divider()
            HStack {
                Spacer()
                Button("关闭") { model.dismissShellFeedback() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 360, idealHeight: 480)
    }
}
