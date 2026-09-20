import SwiftUI

struct ShellView: View {
    @ObservedObject var model: AppModel
    let page: ShellPage

    var body: some View {
        switch page {
        case .overview:
            overview
        case .ohMyZsh, .extensions, .maintenance:
            FeaturePlaceholderView(title: page.title, systemImage: page.systemImage)
        }
    }

    @ViewBuilder
    private var overview: some View {
        if let shell = model.shell {
            ScrollView {
                StatusOverviewCard(tint: .purple) {
                    HStack(spacing: 0) {
                        StatusMetric(
                            title: "Zsh",
                            value: shell.zshVersion ?? "—",
                            systemImage: "terminal.fill",
                            tint: .blue
                        )
                        StatusMetricDivider()
                        StatusMetric(
                            title: "Oh My Zsh",
                            value: shell.ohMyZshInstalled ? "已安装" : "未安装",
                            systemImage: "bolt.fill",
                            tint: shell.ohMyZshInstalled ? .purple : .secondary
                        )
                        StatusMetricDivider()
                        StatusMetric(
                            title: "Oh My Zsh 路径",
                            value: shell.ohMyZshPath,
                            systemImage: "folder.fill",
                            tint: .orange
                        )
                        StatusMetricDivider()
                        StatusMetric(
                            title: "Manager 快照",
                            value: shell.managerAvailable ? "可用" : "缺失",
                            systemImage: "externaldrive.fill",
                            tint: shell.managerAvailable ? .green : .orange
                        )
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            }
        } else if model.isRefreshing {
            PageLoadingView(message: "正在读取 Shell 状态…")
        } else {
            ContentUnavailableView(
                "无法读取 Shell",
                systemImage: "terminal",
                description: Text(model.errorMessages.first(where: { $0.hasPrefix("Shell") }) ?? "请刷新后重试")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
