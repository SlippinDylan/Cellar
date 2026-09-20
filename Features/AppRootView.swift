import SwiftUI

struct AppRootView: View {
    @ObservedObject var model: AppModel
    let updateController: ApplicationUpdateController
    @State private var homebrewExpanded = true
    @State private var nodeExpanded = true
    @State private var shellExpanded = true

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedDestination) {
                Label("概览", systemImage: "square.grid.2x2")
                    .tag(AppDestination.overview)

                sidebarGroup(
                    "Homebrew",
                    systemImage: "mug",
                    isExpanded: $homebrewExpanded,
                    pages: HomebrewPage.allCases,
                    destination: AppDestination.homebrew
                )
                sidebarGroup(
                    "Node",
                    systemImage: "shippingbox",
                    isExpanded: $nodeExpanded,
                    pages: NodePage.allCases,
                    destination: AppDestination.node
                )
                sidebarGroup(
                    "Shell",
                    systemImage: "terminal",
                    isExpanded: $shellExpanded,
                    pages: ShellPage.allCases,
                    destination: AppDestination.shell
                )
            }
            .listStyle(.sidebar)
            .scrollIndicators(.hidden)
            .safeAreaBar(edge: .bottom, alignment: .leading, spacing: 0) {
                VStack(spacing: 2) {
                    utilityRow(.activity, title: "操作记录", systemImage: "clock.arrow.circlepath")
                    utilityRow(.settings, title: "设置", systemImage: "gearshape")
                }
                .padding(8)
                .frame(maxWidth: .infinity)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            VStack(spacing: 0) {
                Divider()
                selectedPage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(model.selectedDestination.navigationTitle)
            .navigationSubtitle(navigationSubtitle)
            .toolbar {
                if model.selectedDestination != .settings {
                    ToolbarItem(placement: .primaryAction) {
                        if model.isBusy {
                            ProgressView()
                                .controlSize(.small)
                                .help("正在执行任务")
                        } else {
                            Button {
                                Task { await model.refresh() }
                            } label: {
                                Label("刷新", systemImage: "arrow.clockwise")
                            }
                            .keyboardShortcut("r", modifiers: .command)
                            .help("刷新本机环境（⌘R）")
                        }
                    }
                }
            }
        }
        .navigationSplitViewStyle(.prominentDetail)
        .task {
            if model.refreshedAt == nil && !AppRuntime.isRunningTests {
                await model.refresh()
            }
        }
    }

    private var navigationSubtitle: String {
        guard model.selectedDestination == .overview, let refreshedAt = model.refreshedAt else {
            return model.selectedDestination.subtitle
        }
        return "\(model.selectedDestination.subtitle)（最后刷新：\(refreshedAt.formatted(date: .omitted, time: .standard))）"
    }

    @ViewBuilder
    private var selectedPage: some View {
        switch model.selectedDestination {
        case .overview: OverviewView(model: model)
        case .homebrew(let page): HomebrewView(model: model, page: page)
        case .node(let page): NodeView(model: model, page: page)
        case .shell(let page): ShellView(model: model, page: page)
        case .activity: ActivityView(model: model)
        case .settings: SettingsView(updateController: updateController)
        }
    }

    private func utilityRow(
        _ destination: AppDestination,
        title: String,
        systemImage: String
    ) -> some View {
        let selected = model.selectedDestination == destination
        return Button {
            model.selectedDestination = destination
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func sidebarGroup<Page: SidebarPage>(
        _ title: String,
        systemImage: String,
        isExpanded: Binding<Bool>,
        pages: [Page],
        destination: @escaping (Page) -> AppDestination
    ) -> some View where Page.ID == Page {
        DisclosureGroup(isExpanded: isExpanded) {
            ForEach(pages) { page in
                Label(page.title, systemImage: page.systemImage)
                    .tag(destination(page))
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

private protocol SidebarPage: Identifiable, Hashable where ID == Self {
    var title: String { get }
    var systemImage: String { get }
}

extension HomebrewPage: SidebarPage {}
extension NodePage: SidebarPage {}
extension ShellPage: SidebarPage {}

enum AppRuntime {
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
