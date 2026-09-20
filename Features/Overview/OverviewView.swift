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
                StatusOverviewCard {
                    HStack(spacing: 0) {
                        StatusMetric(
                            title: "Homebrew",
                            value: model.homebrew?.version ?? "不可用",
                            detail: homebrewDetail,
                            systemImage: "mug.fill",
                            tint: model.homebrew == nil ? .secondary : .blue
                        )
                        StatusMetricDivider()
                        StatusMetric(
                            title: "Node",
                            value: model.node?.summary.nodeVersion ?? "不可用",
                            detail: model.node.map { "\($0.packages.count) 个全局包" } ?? "未读取环境",
                            systemImage: "shippingbox.fill",
                            tint: model.node == nil ? .secondary : .green
                        )
                        StatusMetricDivider()
                        StatusMetric(
                            title: "Shell",
                            value: shellValue,
                            detail: model.shell?.ohMyZshInstalled == true ? "Oh My Zsh 已安装" : "Oh My Zsh 未安装",
                            systemImage: "terminal.fill",
                            tint: model.shell == nil ? .secondary : .purple
                        )
                    }
                }

                if !model.errorMessages.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.errorMessages, id: \.self) { message in
                                Label(message, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label("需要检查", systemImage: "wrench.and.screwdriver")
                    }
                }

                GroupBox {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                        systemRow("Homebrew", model.homebrew?.executablePath ?? "未找到")
                        systemRow("Node", model.node?.summary.nodePath ?? "未找到")
                        systemRow("Shell", model.shell?.zshrcPath ?? "未读取")
                        systemRow(
                            "Manager",
                            model.managers.map { "版本 \($0.version) · \($0.location)" } ?? "尚未安装运行副本"
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .textSelection(.enabled)
                } label: {
                    Label("系统信息", systemImage: "info.circle")
                }

                if let refreshedAt = model.refreshedAt {
                    Label(
                        "最后读取：\(refreshedAt.formatted(date: .abbreviated, time: .standard))",
                        systemImage: "clock"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(24)
        }
    }

    private var homebrewDetail: String {
        guard let homebrew = model.homebrew else { return "未找到 Homebrew" }
        guard let snapshot = homebrew.snapshot else { return homebrew.executablePath ?? "状态不可用" }
        return "\(snapshot.packages.count) 个已安装项目"
    }

    private var shellValue: String {
        guard let version = model.shell?.zshVersion else { return "不可用" }
        return version.replacingOccurrences(of: "zsh ", with: "")
    }

    private func systemRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .fontDesign(.monospaced)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}
