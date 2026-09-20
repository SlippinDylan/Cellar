import SwiftUI

struct HomebrewInstalledPage: View {
    @ObservedObject var model: AppModel
    @State private var filter: HomebrewPackageFilter = .all
    @State private var query = ""
    @State private var selection: HomebrewPackageIdentity?

    var body: some View {
        HomebrewPageState(model: model) { snapshot in
            VStack(spacing: 16) {
                HStack {
                    Picker("类型", selection: $filter) {
                        ForEach(HomebrewPackageFilter.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)

                    Spacer()

                    Text("\(filteredPackages(snapshot).count) 项")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let error = snapshot.sectionErrors[.packages] {
                    HomebrewEmptyState(
                        title: "已安装项目读取失败",
                        detail: error,
                        systemImage: "exclamationmark.triangle"
                    )
                } else if snapshot.packages.isEmpty {
                    HomebrewEmptyState(
                        title: "没有已安装项目",
                        detail: "Homebrew 当前没有报告已安装的 Formula 或 Cask。",
                        systemImage: "shippingbox"
                    )
                } else if filteredPackages(snapshot).isEmpty {
                    HomebrewEmptyState(
                        title: "没有匹配结果",
                        detail: "请调整搜索词或类型筛选。",
                        systemImage: "magnifyingglass"
                    )
                } else {
                    HSplitView {
                        packageTable(snapshot)
                            .frame(minWidth: 430)

                        packageDetail(snapshot)
                            .frame(minWidth: 260, idealWidth: 310, maxWidth: 380)
                    }
                }
            }
            .padding(24)
            .searchable(text: $query, prompt: "搜索已安装的名称或描述")
        }
    }

    private func packageTable(_ snapshot: HomebrewSnapshot) -> some View {
        Table(filteredPackages(snapshot), selection: $selection) {
            TableColumn("名称") { package in
                VStack(alignment: .leading, spacing: 2) {
                    Text(package.displayName)
                    if package.displayName != package.identity.name {
                        Text(package.identity.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            TableColumn("类型") { package in
                Text(package.identity.kind.displayName)
            }
            .width(min: 70, ideal: 78, max: 90)
            TableColumn("版本") { package in
                Text(joinedVersions(package.installedVersions))
            }
            .width(min: 90, ideal: 120)
            TableColumn("来源") { package in
                Text(package.tap ?? "Homebrew")
                    .foregroundStyle(package.tap == nil ? .secondary : .primary)
            }
        }
    }

    @ViewBuilder
    private func packageDetail(_ snapshot: HomebrewSnapshot) -> some View {
        if let selection,
           let package = snapshot.packages.first(where: { $0.identity == selection }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HomebrewPageHeader(
                        title: package.displayName,
                        detail: package.identity.name,
                        systemImage: package.identity.kind == .formula ? "shippingbox.fill" : "app.fill",
                        tint: package.identity.kind == .formula ? .blue : .purple
                    )

                    if let description = package.description {
                        Text(description)
                            .foregroundStyle(.secondary)
                    }

                    detailSection("安装信息") {
                        detailRow("类型", package.identity.kind.displayName)
                        detailRow("版本", joinedVersions(package.installedVersions))
                        detailRow("来源", package.tap ?? "不可用")
                        detailRow("固定版本", package.pinned ? "是" : "否")
                        if let homepage = package.homepage {
                            detailRow("主页", homepage)
                        }
                    }

                    if package.identity.kind == .formula {
                        detailSection("依赖") {
                            Text(package.dependencies.isEmpty ? "没有直接依赖" : package.dependencies.joined(separator: "\n"))
                                .font(.callout)
                                .textSelection(.enabled)
                            Text("被依赖关系会在卸载计划中实时检查。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Button("准备卸载 Formula", role: .destructive) {
                            Task { await model.prepareHomebrewUninstall(package.identity) }
                        }
                        .disabled(model.isBusy)
                    } else {
                        if !package.artifacts.isEmpty {
                            detailSection("Homebrew Artifact") {
                                ForEach(package.artifacts) { artifact in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(artifact.kind) · \(artifact.category == .zap ? "Zap" : "Standard")")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        Text(artifact.values.joined(separator: "\n"))
                                            .font(.callout)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                        Button("准备普通卸载", role: .destructive) {
                                Task { await model.prepareHomebrewUninstall(package.identity) }
                            }
                            .disabled(model.isBusy)

                            Button("准备 Zap 卸载", role: .destructive) {
                                Task { await model.prepareHomebrewUninstall(package.identity, zap: true) }
                            }
                            .disabled(model.isBusy)

                            Text("Zap 可能删除 Cask 定义的用户配置和数据。Cellar 不会使用 sudo，也不会额外删除文件。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        } else {
            HomebrewEmptyState(
                title: "选择一个项目",
                detail: "查看安装信息、依赖和卸载入口。",
                systemImage: "sidebar.right"
            )
        }
    }

    private func filteredPackages(_ snapshot: HomebrewSnapshot) -> [HomebrewPackage] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return snapshot.packages.filter { package in
            filter.includes(package.identity.kind)
                && (term.isEmpty
                    || package.identity.name.localizedCaseInsensitiveContains(term)
                    || package.displayName.localizedCaseInsensitiveContains(term)
                    || package.description?.localizedCaseInsensitiveContains(term) == true)
        }
    }

    private func detailSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}
