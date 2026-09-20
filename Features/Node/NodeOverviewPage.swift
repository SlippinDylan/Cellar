import SwiftUI

struct NodeOverviewPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NodePageContainer(model: model) { node in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    StatusOverviewCard {
                        HStack(spacing: 0) {
                            StatusMetric(title: "Node", value: node.summary.nodeVersion, systemImage: "shippingbox.fill", tint: .green)
                            StatusMetricDivider()
                            StatusMetric(title: "npm", value: node.summary.npmVersion, systemImage: "shippingbox.circle.fill", tint: .red)
                            StatusMetricDivider()
                            StatusMetric(title: "全局包", value: "\(node.packages.count)", systemImage: "square.stack.3d.up.fill", tint: .blue)
                            StatusMetricDivider()
                            StatusMetric(title: "已安装版本", value: "\(node.installations.count)", systemImage: "point.3.connected.trianglepath.dotted", tint: .orange)
                        }
                    }

                    if let outdatedError = node.outdatedError {
                        GroupBox {
                            Label("更新检查失败：\(outdatedError)", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    GroupBox("当前受控环境") {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                            NodeValueRow(label: "Node", value: node.summary.nodePath)
                            NodeValueRow(label: "npm", value: node.summary.npmPath)
                            NodeValueRow(label: "Prefix", value: node.summary.globalPrefix)
                            NodeValueRow(label: "Global Root", value: node.summary.globalRoot)
                            NodeValueRow(label: "Registry", value: node.summary.registry)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    }
                }
                .padding(24)
            }
        }
    }
}

struct NodeValueRow: View {
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
