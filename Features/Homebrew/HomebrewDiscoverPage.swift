import SwiftUI

struct HomebrewDiscoverPage: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var filter: HomebrewPackageFilter = .all
    @State private var selection: HomebrewPackageIdentity?
    @State private var hasSearched = false

    var body: some View {
        HomebrewPageState(model: model) { snapshot in
            VStack(spacing: 18) {
                StatusOverviewCard(tint: .blue) {
                    VStack(alignment: .leading, spacing: 14) {
                        HomebrewPageHeader(
                            title: "查找 Formula 与 Cask",
                            detail: "输入名称后明确搜索；空查询不会请求远端目录。",
                            systemImage: "magnifyingglass"
                        )

                        HStack(spacing: 10) {
                            TextField("例如 wget、visual-studio-code", text: $query)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { search() }

                            Button {
                                search()
                            } label: {
                                HomebrewBusyButtonLabel(
                                    title: "搜索",
                                    workingTitle: "搜索中…",
                                    isWorking: model.isHomebrewWorking
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(trimmedQuery.isEmpty || model.isBusy)
                        }
                    }
                }

                HStack {
                    Picker("类型", selection: $filter) {
                        ForEach(HomebrewPackageFilter.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)

                    Spacer()

                    if hasSearched {
                        Text("\(visibleResults.count) 项结果")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if model.isHomebrewWorking && hasSearched && model.homebrewSearchResults.isEmpty {
                    PageLoadingView(message: "正在搜索 Homebrew…")
                } else if !hasSearched {
                    HomebrewEmptyState(
                        title: "输入关键词开始搜索",
                        detail: "搜索可能访问 Homebrew 服务或第三方 Tap，并更新 Homebrew 自己的 API cache。",
                        systemImage: "safari"
                    )
                } else if visibleResults.isEmpty {
                    HomebrewEmptyState(
                        title: "没有匹配结果",
                        detail: "请尝试其他名称或类型。",
                        systemImage: "magnifyingglass"
                    )
                } else {
                    HSplitView {
                        Table(visibleResults, selection: $selection) {
                            TableColumn("名称") { result in
                                Text(result.identity.name)
                            }
                            TableColumn("类型") { result in
                                Text(result.identity.kind.displayName)
                            }
                            .width(min: 80, ideal: 100, max: 120)
                            TableColumn("状态") { result in
                                Text(installationStatus(result.identity, in: snapshot))
                                    .foregroundStyle(
                                        isInstalled(result.identity, in: snapshot) ? .secondary : .primary
                                    )
                            }
                            .width(min: 70, ideal: 90, max: 110)
                        }
                        .frame(minWidth: 430)

                        resultDetail(snapshot)
                            .frame(minWidth: 250, idealWidth: 300, maxWidth: 360)
                    }
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private func resultDetail(_ snapshot: HomebrewSnapshot) -> some View {
        if let selection {
            VStack(alignment: .leading, spacing: 16) {
                HomebrewPageHeader(
                    title: selection.name,
                    detail: selection.kind.displayName,
                    systemImage: selection.kind == .formula ? "shippingbox.fill" : "app.fill",
                    tint: selection.kind == .formula ? .blue : .purple
                )

                if snapshot.sectionErrors[.packages] != nil {
                    Text("已安装项目状态读取失败，当前无法可靠判断该项目是否已安装。")
                        .foregroundStyle(.orange)
                } else if let installed = snapshot.packages.first(where: { $0.identity == selection }) {
                    Text(installed.description ?? "Homebrew 未提供描述")
                        .foregroundStyle(.secondary)
                    Label("已安装：\(joinedVersions(installed.installedVersions))", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("准备计划时会再次读取 Homebrew 详情，并使用明确的 \(selection.kind.displayName) 类型安装。")
                        .foregroundStyle(.secondary)

                    Button("准备安装 \(selection.kind.displayName)") {
                        Task { await model.prepareHomebrewInstall(selection) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                }

                Text("安装可能联网、下载依赖并修改 Homebrew 管理的目录；实际命令执行前仍需确认计划。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        } else {
            HomebrewEmptyState(
                title: "选择搜索结果",
                detail: "查看类型、安装状态和安装入口。",
                systemImage: "sidebar.right"
            )
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleResults: [HomebrewSearchResult] {
        model.homebrewSearchResults.filter { filter.includes($0.identity.kind) }
    }

    private func isInstalled(_ identity: HomebrewPackageIdentity, in snapshot: HomebrewSnapshot) -> Bool {
        snapshot.packages.contains { package in
            guard package.identity.kind == identity.kind else { return false }
            if package.identity.name == identity.name { return true }
            return !identity.name.contains("/")
                && package.identity.name.hasSuffix("/\(identity.name)")
        }
    }

    private func installationStatus(_ identity: HomebrewPackageIdentity, in snapshot: HomebrewSnapshot) -> String {
        if snapshot.sectionErrors[.packages] != nil {
            return "状态未知"
        }
        return isInstalled(identity, in: snapshot) ? "已安装" : "可安装"
    }

    private func search() {
        guard !trimmedQuery.isEmpty else { return }
        hasSearched = true
        selection = nil
        Task { await model.searchHomebrew(trimmedQuery) }
    }
}
