import SwiftUI

struct HomebrewUpgradesPage: View {
    @ObservedObject var model: AppModel
    @State private var filter: HomebrewPackageFilter = .all
    @State private var selection = Set<HomebrewPackageIdentity>()

    var body: some View {
        HomebrewPageState(model: model) { snapshot in
            VStack(spacing: 16) {
                controls(snapshot)

                if let error = snapshot.sectionErrors[.outdated] {
                    HomebrewEmptyState(
                        title: "可升级项目读取失败",
                        detail: error,
                        systemImage: "exclamationmark.triangle"
                    )
                } else if snapshot.outdatedPackages.isEmpty {
                    HomebrewEmptyState(
                        title: "当前没有可升级项目",
                        detail: "可以先在 Homebrew 概览中更新元数据，再刷新状态。",
                        systemImage: "checkmark.circle"
                    )
                } else if visiblePackages(snapshot).isEmpty {
                    HomebrewEmptyState(
                        title: "此类型没有可升级项目",
                        detail: "请选择其他类型查看。",
                        systemImage: "line.3.horizontal.decrease.circle"
                    )
                } else {
                    Table(visiblePackages(snapshot), selection: $selection) {
                        TableColumn("名称") { package in
                            Text(package.identity.name)
                        }
                        TableColumn("类型") { package in
                            Text(package.identity.kind.displayName)
                        }
                        .width(min: 70, ideal: 90, max: 110)
                        TableColumn("已安装") { package in
                            Text(joinedVersions(package.installedVersions))
                        }
                        TableColumn("可用版本") { package in
                            Text(package.currentVersion ?? "—")
                        }
                    }
                    .alternatingRowBackgrounds(.disabled)

                    Text("Formula 与 Cask 使用不同的明确命令，一次计划只提交一种类型。操作不是事务，失败时可能已有部分项目完成升级。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
            .onChange(of: filter) { _, _ in
                selection.formIntersection(Set(visiblePackages(snapshot).map(\.identity)))
            }
            .onChange(of: snapshot.outdatedPackages.map(\.identity)) { _, identities in
                selection.formIntersection(Set(identities))
            }
        }
    }

    private func controls(_ snapshot: HomebrewSnapshot) -> some View {
        HStack(spacing: 12) {
            Picker("类型", selection: $filter) {
                ForEach(HomebrewPackageFilter.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)

            Button(selectionContainsAllVisible(snapshot) ? "取消全选" : "全选当前列表") {
                let visible = Set(visiblePackages(snapshot).map(\.identity))
                if visible.isSubset(of: selection) {
                    selection.subtract(visible)
                } else {
                    selection.formUnion(visible)
                }
            }
            .disabled(visiblePackages(snapshot).isEmpty || model.isBusy)

            Spacer()

            Text("已选 \(selection.count) 项")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            upgradeControl
        }
    }

    @ViewBuilder
    private var upgradeControl: some View {
        let formulaTargets = selectedTargets(.formula)
        let caskTargets = selectedTargets(.cask)
        if !formulaTargets.isEmpty && !caskTargets.isEmpty {
            Menu {
                Button("为 \(formulaTargets.count) 个 Formula 生成计划") {
                    Task { await model.prepareHomebrewUpgrade(formulaTargets) }
                }
                Button("为 \(caskTargets.count) 个 Cask 生成计划") {
                    Task { await model.prepareHomebrewUpgrade(caskTargets) }
                }
            } label: {
                Label("准备升级…", systemImage: "arrow.up.circle")
            }
            .buttonStyle(.glassProminent)
            .disabled(model.isBusy)
        } else {
            let targets = formulaTargets.isEmpty ? caskTargets : formulaTargets
            Button {
                Task { await model.prepareHomebrewUpgrade(targets) }
            } label: {
                Label("准备升级 \(targets.count) 项", systemImage: "arrow.up.circle")
            }
            .buttonStyle(.glassProminent)
            .disabled(targets.isEmpty || model.isBusy)
        }
    }

    private func visiblePackages(_ snapshot: HomebrewSnapshot) -> [HomebrewOutdatedPackage] {
        snapshot.outdatedPackages.filter { filter.includes($0.identity.kind) }
    }

    private func selectedTargets(_ kind: HomebrewPackageKind) -> [HomebrewPackageIdentity] {
        selection
            .filter { $0.kind == kind }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func selectionContainsAllVisible(_ snapshot: HomebrewSnapshot) -> Bool {
        let visible = Set(visiblePackages(snapshot).map(\.identity))
        return !visible.isEmpty && visible.isSubset(of: selection)
    }
}
