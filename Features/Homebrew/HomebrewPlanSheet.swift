import Foundation
import SwiftUI

struct HomebrewPlanSheet: View {
    @ObservedObject var model: AppModel
    let plan: HomebrewActionPlan

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    StatusOverviewCard(tint: plan.canExecute ? .orange : .red) {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(plan.canExecute ? "执行前确认" : "计划已被安全检查阻止")
                                    .font(.headline)
                                Text(summary)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: plan.canExecute ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(plan.canExecute ? .orange : .red)
                        }
                    }

                    if !plan.targets.isEmpty {
                        planSection("目标", systemImage: "scope") {
                            ForEach(plan.targets, id: \.self) { target in
                                Label("\(target.name)（\(target.kind.displayName)）", systemImage: target.kind == .formula ? "shippingbox" : "app")
                            }
                        }
                    }

                    if let tapName = plan.tapName {
                        planSection("Tap", systemImage: "point.3.connected.trianglepath.dotted") {
                            Text(tapName)
                                .fontDesign(.monospaced)
                                .textSelection(.enabled)
                        }
                    }

                    if !plan.dependencies.isEmpty {
                        stringListSection("直接依赖", values: plan.dependencies, systemImage: "arrow.down.right.and.arrow.up.left")
                    }

                    if !plan.dependents.isEmpty {
                        stringListSection("当前依赖此项目", values: plan.dependents, systemImage: "arrow.triangle.branch")
                    }

                    if !plan.artifacts.isEmpty {
                        planSection("Cask Artifact", systemImage: "doc.on.doc") {
                            ForEach(plan.artifacts) { artifact in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(artifact.kind) · \(artifact.category == .zap ? "Zap" : "Standard")")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(artifact.values.joined(separator: "\n"))
                                        .font(.callout)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }

                    if !plan.residualPaths.isEmpty {
                        planSection("当前存在的精确路径", systemImage: "folder.badge.questionmark") {
                            HStack {
                                Text("预计占用空间")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(estimatedSizeSummary(plan.residualPaths))
                                    .font(.headline.monospacedDigit())
                            }

                            Divider()

                            ForEach(plan.residualPaths) { residual in
                                residualPathRow(residual)
                            }

                            Text("仅列出 Homebrew artifact 中明确声明、可解析且当前存在的精确路径；不展开 glob，也不进行名称或 bundle ID 模糊扫描。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !plan.associatedPackages.isEmpty {
                        planSection("阻止移除的关联安装项", systemImage: "lock.trianglebadge.exclamationmark") {
                            ForEach(plan.associatedPackages, id: \.self) { package in
                                Text("\(package.name)（\(package.kind.displayName)）")
                            }
                        }
                    }

                    planSection("边界与风险", systemImage: "checklist") {
                        ForEach(riskNotes, id: \.self) { note in
                            Label(note, systemImage: "circle.fill")
                                .labelStyle(HomebrewBulletLabelStyle())
                        }
                    }

                    Label(
                        "计划生成于 \(plan.generatedAt.formatted(date: .abbreviated, time: .standard))",
                        systemImage: "clock"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Divider()
            sheetActions
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 520, idealHeight: 640)
    }

    private var sheetHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: plan.isDestructive ? "exclamationmark.shield.fill" : "shippingbox.fill")
                .font(.title2)
                .foregroundStyle(plan.isDestructive ? .red : .blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.title)
                    .font(.title3.weight(.semibold))
                Text("Homebrew 操作计划")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var sheetActions: some View {
        HStack {
            if !plan.canExecute {
                Label("请先处理关联安装项", systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Spacer()
            Button("取消", role: .cancel) {
                model.dismissHomebrewPlan()
            }
            .keyboardShortcut(.cancelAction)

            Button(role: plan.isDestructive ? .destructive : nil) {
                Task { await model.executeHomebrewPlan() }
            } label: {
                Text(plan.confirmationTitle)
            }
            .buttonStyle(.borderedProminent)
            .tint(plan.isDestructive ? .red : .accentColor)
            .keyboardShortcut(.defaultAction)
            .disabled(!plan.canExecute || model.isHomebrewWorking)
        }
        .padding(20)
    }

    private var summary: String {
        switch plan.action {
        case .update:
            "将更新 Homebrew 与 Tap 元数据，不会自动升级已安装项目。"
        case .addTap:
            "将添加指定 Tap，它可能访问第三方仓库并写入 Homebrew 管理的状态。"
        case .removeTap:
            plan.canExecute
                ? "将移除指定 Tap；关联安装项检查已通过。"
                : "该 Tap 仍提供已安装项目，因此不能移除。"
        case .zapCask:
            "Zap 会请求 Homebrew 删除 Cask 及其定义的关联文件，其中可能包含用户数据。"
        default:
            "将对列出的精确目标执行 \(plan.title)。"
        }
    }

    private var riskNotes: [String] {
        var notes = [
            "Homebrew 写操作不是事务；失败时可能已有部分更改完成。",
            "执行结束后 Cellar 会重新读取真实状态，不承诺自动回滚。",
            "Cellar 不使用 sudo 或 Privileged Helper。",
        ]
        if plan.action == .uninstallFormula || plan.action == .uninstallCask || plan.action == .zapCask {
            notes.append("卸载明确禁止隐式自动更新和 autoremove。")
            notes.append("Cellar 不会自行删除或补删任何 artifact。")
        }
        if plan.action == .zapCask {
            notes.append("Zap 可能由 Homebrew 删除 Cask 定义的用户配置与数据。")
        }
        return notes
    }

    private func planSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    private func stringListSection(_ title: String, values: [String], systemImage: String) -> some View {
        planSection(title, systemImage: systemImage) {
            ForEach(values, id: \.self) { value in
                Text(value)
                    .textSelection(.enabled)
            }
        }
    }

    private func residualPathRow(_ residual: HomebrewResidualPath) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(residual.path)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Text(residual.artifactKind)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(residual.estimatedBytes.map(formattedByteCount) ?? "无法估算")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func estimatedSizeSummary(_ paths: [HomebrewResidualPath]) -> String {
        let knownSizes = paths.compactMap(\.estimatedBytes)
        let formatted = formattedByteCount(knownSizes.reduce(0, +))
        return knownSizes.count == paths.count ? formatted : "\(formatted)（不含无法估算项）"
    }
}

struct HomebrewResultSheet: View {
    @ObservedObject var model: AppModel
    let result: HomebrewActionResult

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: result.outcome.systemImage)
                    .font(.title2)
                    .foregroundStyle(result.outcome.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.outcome.title)
                        .font(.title3.weight(.semibold))
                    Text(result.plan.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    StatusOverviewCard(tint: result.outcome.tint) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(result.outcome.detail)
                                .font(.headline)
                            Text("退出状态：\(result.command.terminationStatus)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    outputSection("命令", text: "brew " + result.command.arguments.joined(separator: " "))
                    if !result.command.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        outputSection("标准输出", text: result.command.standardOutput)
                        if result.command.standardOutputWasTruncated {
                            truncationNotice("标准输出")
                        }
                    }
                    if !result.command.standardError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        outputSection("错误输出", text: result.command.standardError)
                        if result.command.standardErrorWasTruncated {
                            truncationNotice("错误输出")
                        }
                    }
                    if let postflightError = result.postflightError {
                        outputSection("状态复查错误", text: postflightError)
                    }

                    if !result.remainingResidualPaths.isEmpty {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(result.remainingResidualPaths) { residual in
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(residual.path)
                                                .font(.system(.callout, design: .monospaced))
                                                .textSelection(.enabled)
                                            Text(residual.artifactKind)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(residual.estimatedBytes.map(formattedByteCount) ?? "无法估算")
                                            .font(.callout.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Divider()

                                Text("这些是 postflight 复查时仍存在的 Homebrew 声明路径。Cellar 仅报告，不会使用 sudo 或自行补删。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                        } label: {
                            Label("仍存在的声明路径", systemImage: "folder.badge.exclamationmark")
                        }
                    } else if !result.plan.residualPaths.isEmpty {
                        Label("Postflight 未发现计划中列出的精确路径仍然存在。", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                    }

                    Text("Cellar 没有使用 sudo，也没有在 Homebrew 命令后额外删除文件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Divider()
            HStack {
                Spacer()
                Button("关闭") {
                    model.dismissHomebrewFeedback()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 480, idealHeight: 600)
    }

    private func outputSection(_ title: String, text: String) -> some View {
        GroupBox(title) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }
    }

    private func truncationNotice(_ stream: String) -> some View {
        Label("\(stream)超过保留上限，以上内容已截断。", systemImage: "scissors")
            .font(.caption)
            .foregroundStyle(.orange)
    }
}

private func formattedByteCount(_ byteCount: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
}

private struct HomebrewBulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon
                .font(.system(size: 5))
                .foregroundStyle(.secondary)
            configuration.title
        }
    }
}

private extension HomebrewActionPlan {
    var title: String {
        switch action {
        case .install: "安装软件包"
        case .upgrade: "升级软件包"
        case .update: "更新 Homebrew 元数据"
        case .addTap: "添加 Tap"
        case .removeTap: "移除 Tap"
        case .uninstallFormula: "卸载 Formula"
        case .uninstallCask: "普通卸载 Cask"
        case .zapCask: "Zap 卸载 Cask"
        }
    }

    var confirmationTitle: String {
        switch action {
        case .install: "确认安装"
        case .upgrade: "确认升级"
        case .update: "确认更新"
        case .addTap: "确认添加"
        case .removeTap: "确认移除"
        case .uninstallFormula, .uninstallCask: "确认卸载"
        case .zapCask: "确认 Zap 卸载"
        }
    }

    var isDestructive: Bool {
        switch action {
        case .removeTap, .uninstallFormula, .uninstallCask, .zapCask: true
        case .install, .upgrade, .update, .addTap: false
        }
    }
}

private extension HomebrewActionResult.Outcome {
    var title: String {
        switch self {
        case .succeeded: "Homebrew 操作完成"
        case .partial: "Homebrew 操作部分完成"
        case .failed: "Homebrew 操作未达到目标状态"
        case .stateUnknown: "Homebrew 操作结果待确认"
        }
    }

    var detail: String {
        switch self {
        case .succeeded:
            "命令成功，并已重新读取 Homebrew 状态。"
        case .partial:
            "命令返回失败，但复查显示目标状态已经改变；请检查下方输出。"
        case .failed:
            "复查显示目标状态没有完成。操作不是事务，其他依赖或缓存仍可能已经变化。"
        case .stateUnknown:
            "执行后无法读取判断目标所需的状态。请刷新并以实际 Homebrew 状态为准。"
        }
    }

    var systemImage: String {
        switch self {
        case .succeeded: "checkmark.circle.fill"
        case .partial: "exclamationmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .stateUnknown: "questionmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .succeeded: .green
        case .partial, .stateUnknown: .orange
        case .failed: .red
        }
    }
}
