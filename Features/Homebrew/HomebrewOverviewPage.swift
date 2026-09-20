import SwiftUI

struct HomebrewOverviewPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HomebrewPageState(model: model) { snapshot in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(sectionErrors(snapshot).enumerated()), id: \.offset) { _, error in
                        HomebrewSectionErrorCard(title: error.title, message: error.message)
                    }

                    StatusOverviewCard(tint: .blue) {
                        HStack(spacing: 0) {
                            StatusMetric(
                                title: "Formula",
                                value: snapshot.sectionErrors[.packages] == nil
                                    ? "\(snapshot.packages.filter { $0.identity.kind == .formula }.count)"
                                    : "—",
                                systemImage: "shippingbox.fill",
                                tint: .blue
                            )
                            StatusMetricDivider()
                            StatusMetric(
                                title: "Cask",
                                value: snapshot.sectionErrors[.packages] == nil
                                    ? "\(snapshot.packages.filter { $0.identity.kind == .cask }.count)"
                                    : "—",
                                systemImage: "app.fill",
                                tint: .purple
                            )
                            StatusMetricDivider()
                            StatusMetric(
                                title: "Tap",
                                value: snapshot.sectionErrors[.taps] == nil ? "\(snapshot.taps.count)" : "—",
                                systemImage: "point.3.connected.trianglepath.dotted",
                                tint: .green
                            )
                            StatusMetricDivider()
                            StatusMetric(
                                title: "可升级",
                                value: snapshot.sectionErrors[.outdated] == nil
                                    ? "\(snapshot.outdatedPackages.count)"
                                    : "—",
                                systemImage: "arrow.up.circle.fill",
                                tint: snapshot.outdatedPackages.isEmpty ? .green : .orange
                            )
                        }
                        .frame(maxWidth: .infinity)
                    }

                    GroupBox {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                            overviewRow("版本", snapshot.version)
                            overviewRow("brew", snapshot.executablePath)
                            overviewRow("Prefix", snapshot.configuration.prefix)
                            overviewRow("Repository", snapshot.configuration.repository)
                            overviewRow("Cache", snapshot.configuration.cache)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .textSelection(.enabled)
                    } label: {
                        Label("运行环境", systemImage: "terminal")
                    }

                    StatusOverviewCard(tint: .orange) {
                        HStack(spacing: 16) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 24))
                                .foregroundStyle(.orange)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("更新 Homebrew 元数据")
                                    .font(.headline)
                                Text("这是独立写操作，会先生成计划并等待确认；不会自动升级已安装项目。")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                Task { await model.prepareHomebrewUpdate() }
                            } label: {
                                HomebrewBusyButtonLabel(
                                    title: "检查计划",
                                    workingTitle: "准备中…",
                                    isWorking: model.isHomebrewWorking
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isBusy)
                        }
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
    }

    private func overviewRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value)
                .fontDesign(.monospaced)
        }
    }

    private func sectionErrors(_ snapshot: HomebrewSnapshot) -> [(title: String, message: String)] {
        let titles: [HomebrewSnapshot.Section: String] = [
            .configuration: "配置读取失败",
            .packages: "已安装项目读取失败",
            .outdated: "可升级项目读取失败",
            .taps: "Tap 读取失败",
        ]
        return snapshot.sectionErrors
            .map { (titles[$0.key] ?? "Homebrew 分区读取失败", $0.value) }
            .sorted { $0.0 < $1.0 }
    }
}
