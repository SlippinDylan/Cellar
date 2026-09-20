import SwiftUI

struct HomebrewDoctorPage: View {
    @ObservedObject var model: AppModel
    @State private var hasRunDoctor = false

    var body: some View {
        HomebrewPageState(model: model) { snapshot in
            VStack(alignment: .leading, spacing: 18) {
                if let error = snapshot.sectionErrors[.configuration] {
                    HomebrewSectionErrorCard(title: "Homebrew 配置读取失败", message: error)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    environmentCard(
                        title: "Command Line Tools",
                        value: snapshot.commandLineToolsAvailable ? "可用" : "不可用",
                        detail: "Cellar 只检查状态，不提供安装入口。",
                        systemImage: "hammer.fill",
                        tint: snapshot.commandLineToolsAvailable ? .green : .orange
                    )
                    environmentCard(
                        title: "brew 可执行文件",
                        value: snapshot.executablePath,
                        detail: "所有命令固定使用此绝对路径。",
                        systemImage: "terminal.fill",
                        tint: .blue
                    )
                }

                GroupBox {
                    Text(snapshot.controlledPath)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } label: {
                    Label("受控 PATH", systemImage: "point.3.filled.connected.trianglepath.dotted")
                }

                HStack {
                    HomebrewPageHeader(
                        title: "brew doctor",
                        detail: "仅在你主动运行时检查；警告与非零退出都作为诊断结果保留。",
                        systemImage: "stethoscope",
                        tint: .purple
                    )

                    Button {
                        hasRunDoctor = true
                        Task { await model.diagnoseHomebrew() }
                    } label: {
                        HomebrewBusyButtonLabel(
                            title: hasRunDoctor ? "重新运行" : "运行诊断",
                            workingTitle: "诊断中…",
                            isWorking: model.isHomebrewWorking
                        )
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(model.isBusy)
                }

                if let report = model.homebrewDiagnosticReport {
                    diagnosticCommandSummary(report)
                }

                if model.isHomebrewWorking && hasRunDoctor {
                    PageLoadingView(message: "正在运行 brew doctor…")
                } else if !hasRunDoctor && model.homebrewDiagnostics.isEmpty {
                    HomebrewEmptyState(
                        title: "尚未运行诊断",
                        detail: "brew doctor 可能需要一些时间，并可能访问 Homebrew 管理的状态。",
                        systemImage: "stethoscope"
                    )
                } else if model.homebrewDiagnostics.isEmpty {
                    HomebrewEmptyState(
                        title: "没有诊断输出",
                        detail: "brew doctor 没有返回可显示的内容。",
                        systemImage: "checkmark.circle"
                    )
                } else {
                    List(model.homebrewDiagnostics) { diagnostic in
                        Label {
                            Text(diagnostic.message)
                                .textSelection(.enabled)
                        } icon: {
                            Image(systemName: diagnostic.severity.systemImage)
                                .foregroundStyle(diagnostic.severity.tint)
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.inset)
                }
            }
            .padding(24)
        }
    }

    private func environmentCard(
        title: String,
        value: String,
        detail: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        StatusOverviewCard {
            StatusMetric(
                title: title,
                value: value,
                detail: detail,
                systemImage: systemImage,
                tint: tint
            )
            .frame(minHeight: 64)
        }
    }

    private func diagnosticCommandSummary(_ report: HomebrewDiagnosticReport) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(
                        report.command.terminationStatus == 0 ? "命令正常结束" : "命令返回非零状态",
                        systemImage: report.command.terminationStatus == 0
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(report.command.terminationStatus == 0 ? .green : .orange)
                    Spacer()
                    Text("退出状态 \(report.command.terminationStatus)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if !report.command.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    diagnosticOutput("标准输出", report.command.standardOutput)
                }
                if !report.command.standardError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    diagnosticOutput("错误输出", report.command.standardError)
                }
                if report.command.standardOutputWasTruncated || report.command.standardErrorWasTruncated {
                    Label("诊断输出超过保留上限，显示内容已截断。", systemImage: "scissors")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        } label: {
            Label("命令结果", systemImage: "terminal")
        }
    }

    private func diagnosticOutput(_ title: String, _ output: String) -> some View {
        DisclosureGroup(title) {
            Text(displayed(output))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        }
    }

    private func displayed(_ output: String) -> String {
        let limit = 100_000
        return output.count > limit ? String(output.prefix(limit)) + "\n… UI 显示已截断" : output
    }

}

private extension HomebrewDiagnosticSeverity {
    var systemImage: String {
        switch self {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}
