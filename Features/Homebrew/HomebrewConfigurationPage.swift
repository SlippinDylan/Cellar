import SwiftUI

struct HomebrewConfigurationPage: View {
    @ObservedObject var model: AppModel
    @State private var selectedTap: String?
    @State private var showingAddTap = false

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
            .onChange(of: snapshot.taps.map(\.name)) { _, names in
                if let selectedTap, !names.contains(selectedTap) {
                    self.selectedTap = nil
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAddTap = true } label: {
                        Label("添加 Tap", systemImage: "plus")
                    }
                    .disabled(model.isBusy)
                }
            }
            .sheet(isPresented: $showingAddTap) {
                AddTapSheet(model: model)
            }
        }
    }

    private func pathCard(_ snapshot: HomebrewSnapshot) -> some View {
        StatusOverviewCard {
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
                                .frame(width: 180, alignment: .leading)
                            Text(snapshot.configuration.values[key] ?? "—")
                                .fontDesign(.monospaced)
                                .textSelection(.enabled)
                                .lineLimit(3)
                                .truncationMode(.middle)
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
                HStack {
                    Text("选择 Tap 后可以先扫描关联安装项，再生成安全移除计划。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("安全移除", role: .destructive) {
                        guard let selectedTap else { return }
                        Task { await model.prepareHomebrewRemoveTap(selectedTap) }
                    }
                    .disabled(
                        selectedTap == nil
                            || model.isBusy
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
                        description: Text("可以从工具栏添加 user/repository。")
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
                    .alternatingRowBackgrounds(.disabled)
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
                .frame(width: 120, alignment: .leading)
            Text(value)
                .fontDesign(.monospaced)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private func cellarPath(_ snapshot: HomebrewSnapshot) -> String {
        snapshot.configuration.cellar
    }

}

private struct AddTapSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @State private var tapName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("添加 Homebrew Tap", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.title2.weight(.semibold))
            TextField("user/repository", text: $tapName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(prepare)
            Text("第三方 Tap 可能访问网络并修改 Homebrew 管理的仓库状态。下一步只生成计划。")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("生成计划") { prepare() }
                    .buttonStyle(.glassProminent)
                    .disabled(trimmedName.isEmpty || model.isBusy)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var trimmedName: String {
        tapName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func prepare() {
        guard !trimmedName.isEmpty else { return }
        dismiss()
        Task { await model.prepareHomebrewAddTap(trimmedName) }
    }
}
