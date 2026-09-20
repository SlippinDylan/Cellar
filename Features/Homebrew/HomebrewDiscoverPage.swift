import SwiftUI

struct HomebrewDiscoverPage: View {
    @ObservedObject var model: AppModel
    @State private var showingSearch = false
    @State private var showingBatchInstall = false

    var body: some View {
        HomebrewPageState(model: model) { snapshot in
            VStack(spacing: 18) {
                Image(systemName: "safari")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.secondary)

                VStack(spacing: 6) {
                    Text("发现 Homebrew 软件")
                        .font(.title2.weight(.semibold))
                    Text("搜索 Formula 与 Cask，或一次粘贴多个名称生成批量安装计划。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 10) {
                    Button {
                        showingSearch = true
                    } label: {
                        Label("查找软件…", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.glassProminent)

                    Button {
                        showingBatchInstall = true
                    } label: {
                        Label("批量安装…", systemImage: "text.badge.plus")
                    }
                    .buttonStyle(.glass)
                }

                Label("只有在你提交搜索或确认计划后才会访问网络。", systemImage: "network")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
            .sheet(isPresented: $showingSearch) {
                HomebrewSearchSheet(model: model, snapshot: snapshot)
            }
            .sheet(isPresented: $showingBatchInstall) {
                HomebrewBatchInstallSheet(model: model)
            }
        }
    }
}
