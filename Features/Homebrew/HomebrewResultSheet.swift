import SwiftUI

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
                    StatusOverviewCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(resultDetail)
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
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 480, idealHeight: 600)
    }

    private func outputSection(_ title: String, text: String) -> some View {
        GroupBox(title) {
            Text(displayed(text))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }
    }

    private func displayed(_ text: String) -> String {
        let limit = 100_000
        return text.count > limit ? String(text.prefix(limit)) + "\n… UI 显示已截断" : text
    }

    private func truncationNotice(_ stream: String) -> some View {
        Label("\(stream)超过保留上限，以上内容已截断。", systemImage: "scissors")
            .font(.caption)
            .foregroundStyle(.orange)
    }

    private var resultDetail: String {
        if result.outcome == .partial, result.command.terminationStatus == 0 {
            return "命令成功结束，但复查未确认所有目标；请检查下方输出和当前状态。"
        }
        return result.outcome.detail
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
