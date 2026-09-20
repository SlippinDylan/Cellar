import SwiftUI

struct OverviewView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.isRefreshing && model.refreshedAt == nil {
            PageLoadingView(message: "正在读取本机环境…")
        } else {
            overviewContent
        }
    }

    private var overviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 16
                ) {
                    statusCard(
                        title: "Homebrew",
                        icon: "mug",
                        tint: .blue,
                        value: model.homebrew?.version ?? "不可用",
                        detail: model.homebrew?.executablePath ?? "未找到 Homebrew"
                    )
                    statusCard(
                        title: "Node",
                        icon: "shippingbox",
                        tint: .green,
                        value: model.node?.summary.nodeVersion ?? "不可用",
                        detail: model.node.map { "\($0.packages.count) 个全局包" } ?? "未读取 Node 环境"
                    )
                    statusCard(
                        title: "Shell",
                        icon: "terminal",
                        tint: .purple,
                        value: model.shell?.zshVersion ?? "不可用",
                        detail: model.shell?.ohMyZshInstalled == true ? "Oh My Zsh 已安装" : "Oh My Zsh 未安装"
                    )
                    statusCard(
                        title: "Manager 快照",
                        icon: "externaldrive",
                        tint: .orange,
                        value: model.managers.map { "版本 \($0.version)" } ?? "不可用",
                        detail: model.managers?.location ?? "尚未安装运行副本"
                    )
                }
                .frame(maxWidth: .infinity)

                if !model.errorMessages.isEmpty {
                    GroupBox("部分状态读取失败") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.errorMessages, id: \.self) { message in
                                Label(message, systemImage: "exclamationmark.triangle")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(24)
        }
    }

    private func statusCard(
        title: String,
        icon: String,
        tint: Color,
        value: String,
        detail: String
    ) -> some View {
        StatusOverviewCard(tint: tint) {
            StatusMetric(
                title: title,
                value: value,
                detail: detail,
                systemImage: icon,
                tint: tint
            )
            .frame(minHeight: 72)
        }
        .frame(maxWidth: .infinity)
    }
}
