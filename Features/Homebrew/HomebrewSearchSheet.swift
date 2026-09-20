import SwiftUI

struct HomebrewSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let snapshot: HomebrewSnapshot

    @State private var query = ""
    @State private var filter: HomebrewPackageFilter = .all
    @State private var selection: HomebrewPackageIdentity?
    @State private var hasSearched = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("查找 Homebrew 软件")
                        .font(.title3.weight(.semibold))
                    Text("搜索不会立即安装；选中项目后再生成计划。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    TextField("例如 wget、visual-studio-code", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(search)

                    Button(action: search) {
                        if model.isHomebrewWorking {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("搜索")
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(trimmedQuery.isEmpty || model.isBusy)
                }

                HStack {
                    Picker("类型", selection: $filter) {
                        ForEach(HomebrewPackageFilter.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)
                    .onChange(of: filter) { _, _ in selection = nil }

                    Spacer()
                    if hasSearched {
                        Text("\(visibleResults.count) 项")
                            .foregroundStyle(.secondary)
                    }
                }

                resultContent
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("生成安装计划") { prepareInstall() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canPrepareInstall || model.isBusy)
            }
            .padding(20)
        }
        .frame(minWidth: 760, idealWidth: 880, minHeight: 520, idealHeight: 640)
    }

    @ViewBuilder
    private var resultContent: some View {
        if model.isHomebrewWorking && hasSearched && model.homebrewSearchResults.isEmpty {
            PageLoadingView(message: "正在搜索 Homebrew…")
        } else if !hasSearched {
            ContentUnavailableView(
                "输入关键词开始搜索",
                systemImage: "magnifyingglass",
                description: Text("支持 Formula 和 Cask；空查询不请求远程目录。")
            )
        } else if visibleResults.isEmpty {
            ContentUnavailableView.search(text: trimmedQuery)
        } else {
            HSplitView {
                Table(visibleResults, selection: $selection) {
                    TableColumn("名称") { Text($0.identity.name) }
                    TableColumn("类型") { Text($0.identity.kind.displayName) }
                        .width(min: 80, ideal: 100, max: 120)
                    TableColumn("状态") { result in
                        Text(isInstalled(result.identity) ? "已安装" : "可安装")
                            .foregroundStyle(isInstalled(result.identity) ? .secondary : .primary)
                    }
                    .width(min: 80, ideal: 100, max: 120)
                }
                .alternatingRowBackgrounds(.disabled)
                .frame(minWidth: 430)

                inspector
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 380)
            }
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let selection {
            VStack(alignment: .leading, spacing: 16) {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selection.name).font(.headline)
                        Text(selection.kind.displayName).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: selection.kind == .formula ? "shippingbox.fill" : "app.fill")
                        .font(.title2)
                        .foregroundStyle(selection.kind == .formula ? .blue : .purple)
                }

                if isInstalled(selection) {
                    Label("已安装", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("计划会再次读取详情，并用明确类型调用 Homebrew。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView("选择一个项目", systemImage: "sidebar.right")
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleResults: [HomebrewSearchResult] {
        model.homebrewSearchResults.filter { filter.includes($0.identity.kind) }
    }

    private var canPrepareInstall: Bool {
        selection.map { !isInstalled($0) } ?? false
    }

    private func isInstalled(_ identity: HomebrewPackageIdentity) -> Bool {
        snapshot.packages.contains { package in
            guard package.identity.kind == identity.kind else { return false }
            return package.identity.name == identity.name
                || (!identity.name.contains("/") && package.identity.name.hasSuffix("/\(identity.name)"))
        }
    }

    private func search() {
        guard !trimmedQuery.isEmpty else { return }
        hasSearched = true
        selection = nil
        Task { await model.searchHomebrew(trimmedQuery) }
    }

    private func prepareInstall() {
        guard let selection, !isInstalled(selection) else { return }
        dismiss()
        Task { await model.prepareHomebrewInstall(selection) }
    }
}
