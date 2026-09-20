import SwiftUI

struct ShellOverviewPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ShellPageContainer(model: model) { shell in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    StatusOverviewCard {
                        HStack(spacing: 0) {
                            StatusMetric(title: "Zsh", value: shell.zshVersion ?? "—", systemImage: "terminal.fill", tint: .blue)
                            StatusMetricDivider()
                            StatusMetric(title: "Oh My Zsh", value: shell.ohMyZshInstalled ? "已安装" : "未安装", systemImage: "bolt.fill", tint: shell.ohMyZshInstalled ? .purple : .secondary)
                            StatusMetricDivider()
                            StatusMetric(title: "插件", value: "\(shell.activePlugins.count)", systemImage: "puzzlepiece.extension.fill", tint: .green)
                            StatusMetricDivider()
                            StatusMetric(title: "主题", value: shell.currentTheme.isEmpty ? "未设置" : shell.currentTheme, systemImage: "paintbrush.fill", tint: .orange)
                        }
                    }
                    GroupBox("配置位置") {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                            ShellValueRow(label: "Oh My Zsh", value: shell.ohMyZshPath)
                            ShellValueRow(label: ".zshrc", value: shell.zshrcPath)
                            ShellValueRow(label: "运行数据", value: shell.runtimeDirectory)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                }
                .padding(24)
            }
        }
    }
}

struct ShellValueRow: View {
    let label: String
    let value: String

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .fontDesign(.monospaced)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}
