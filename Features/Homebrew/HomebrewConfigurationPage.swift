import SwiftUI

struct HomebrewConfigurationPage: View {
    @ObservedObject var model: AppModel
    @State private var tapName = ""
    @State private var selectedTap: String?

    var body: some View {
        HomebrewPageState(model: model) { snapshot in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let error = snapshot.sectionErrors[.configuration] {
                        HomebrewSectionErrorCard(title: "配置读取失败", message: error)
                    } else {
                        pathCard(snapshot)
                        configurationCard(snapshot)
                    }
                    tapsCard(snapshot)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(24)
            }
        }
    }

    private func pathCard(_ snapshot: HomebrewSnapshot) -> some View {
        StatusOverviewCard(tint: .blue) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                pathRow("Prefix", snapshot.configuration.prefix)
                pathRow("Repository", snapshot.configuration.repository)
                pathRow("Cache", snapshot.configuration.cache)
                pathRow("Cellar", cellarPath(snapshot))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    private func configurationCard(_ snapshot: HomebrewSnapshot) -> some View {
        GroupBox {
            if snapshot.configuration.values.isEmpty {
                Text("brew config 没有返回配置项")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    ForEach(snapshot.configuration.values.keys.sorted(), id: \.self) { key in
                        GridRow {
                            Text(key)
                                .foregroundStyle(.secondary)
                            Text(snapshot.configuration.values[key] ?? "—")
                                .fontDesign(.monospaced)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        } label: {
            Label("Homebrew 配置", systemImage: "gearshape")
        }
    }

    private func tapsCard(_ snapshot: HomebrewSnapshot) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    TextField("user/repository", text: $tapName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { prepareAddTap() }

                    Button("添加 Tap") {
                        prepareAddTap()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedTapName.isEmpty || model.isHomebrewWorking || model.isRefreshing)

                    Spacer()

                    Button("安全移除", role: .destructive) {
                        guard let selectedTap else { return }
                        Task { await model.prepareHomebrewRemoveTap(selectedTap) }
                    }
                    .disabled(
                        selectedTap == nil
                            || model.isHomebrewWorking
                            || model.isRefreshing
                            || snapshot.sectionErrors[.taps] != nil
                    )
                }

                if let error = snapshot.sectionErrors[.taps] {
                    ContentUnavailableView(
                        "Tap 读取失败",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else if snapshot.taps.isEmpty {
                    ContentUnavailableView(
                        "没有额外 Tap",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text("可以输入 user/repository 添加 Tap。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    Table(snapshot.taps, selection: $selectedTap) {
                        TableColumn("名称", value: \.name)
                        TableColumn("来源") { tap in
                            Text(tap.remote ?? "—")
                        }
                        TableColumn("Formula") { tap in
                            Text("\(tap.formulaNames.count)")
                        }
                        .width(min: 65, ideal: 75, max: 90)
                        TableColumn("Cask") { tap in
                            Text("\(tap.caskTokens.count)")
                        }
                        .width(min: 55, ideal: 65, max: 80)
                    }
                    .frame(minHeight: 220, idealHeight: 280)
                }

                Text("移除前会扫描关联的已安装 Formula/Cask；存在关联项目时计划不可执行。Tap 变更不是事务。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } label: {
            Label("Tap 管理", systemImage: "point.3.connected.trianglepath.dotted")
        }
    }

    private func pathRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .fontDesign(.monospaced)
        }
    }

    private func cellarPath(_ snapshot: HomebrewSnapshot) -> String {
        snapshot.configuration.cellar
    }

    private var trimmedTapName: String {
        tapName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func prepareAddTap() {
        guard !trimmedTapName.isEmpty else { return }
        let name = trimmedTapName
        Task { await model.prepareHomebrewAddTap(name) }
    }
}
