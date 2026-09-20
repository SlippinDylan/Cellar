import SwiftUI

struct NodeView: View {
    @ObservedObject var model: AppModel
    let page: NodePage

    var body: some View {
        switch page {
        case .overview:
            overview
        case .packages, .versions, .registry, .maintenance:
            FeaturePlaceholderView(title: page.title, systemImage: page.systemImage)
        }
    }

    @ViewBuilder
    private var overview: some View {
        if let node = model.node {
            nodeContent(node)
        } else if model.isRefreshing {
            PageLoadingView(message: "正在读取 Node 与全局包…")
        } else {
            ContentUnavailableView(
                "无法读取 Node",
                systemImage: "shippingbox",
                description: Text(model.errorMessages.first(where: { $0.hasPrefix("Node") }) ?? "请刷新后重试")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func nodeContent(_ node: NodeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            StatusOverviewCard(tint: .blue) {
                HStack(spacing: 0) {
                    StatusMetric(
                        title: "Node",
                        value: node.summary.nodeVersion,
                        systemImage: "shippingbox.fill",
                        tint: .green
                    )
                    StatusMetricDivider()
                    StatusMetric(
                        title: "npm",
                        value: node.summary.npmVersion,
                        systemImage: "shippingbox.circle.fill",
                        tint: .red
                    )
                    StatusMetricDivider()
                    StatusMetric(
                        title: "全局包",
                        value: "\(node.packages.count)",
                        systemImage: "square.stack.3d.up.fill",
                        tint: .blue
                    )
                    StatusMetricDivider()
                    StatusMetric(
                        title: "可更新",
                        value: "\(node.packages.filter(\.isOutdated).count)",
                        systemImage: "arrow.up.circle.fill",
                        tint: node.packages.contains(where: \.isOutdated) ? .orange : .green
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)

            if let outdatedError = node.outdatedError {
                GroupBox {
                    Label("更新检查失败：\(outdatedError)", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
            }

            Table(node.packages) {
                TableColumn("包名", value: \.name)
                TableColumn("当前版本", value: \.installedVersion)
                TableColumn("Wanted") { package in
                    Text(package.wantedVersion ?? "—")
                }
                TableColumn("Latest") { package in
                    Text(package.latestVersion ?? "—")
                }
            }

            GroupBox("npm 配置") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow { Text("Registry").foregroundStyle(.secondary); Text(node.configuration.registry) }
                    GridRow { Text("Prefix").foregroundStyle(.secondary); Text(node.configuration.prefix) }
                    GridRow { Text("Cache").foregroundStyle(.secondary); Text(node.configuration.cache) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
    }
}
