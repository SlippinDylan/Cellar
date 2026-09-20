import SwiftUI

struct AppRootView: View {
    @ObservedObject var model: AppModel
    @State private var homebrewExpanded = true
    @State private var nodeExpanded = true
    @State private var shellExpanded = true

    var body: some View {
        NavigationSplitView {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    SidebarDestinationRow(
                        destination: .overview,
                        title: "概览",
                        systemImage: "square.grid.2x2",
                        selection: $model.selectedDestination
                    )

                    SidebarGroup(
                        title: "Homebrew",
                        systemImage: "mug",
                        isExpanded: $homebrewExpanded
                    ) {
                        ForEach(HomebrewPage.allCases) { page in
                            SidebarDestinationRow(
                                destination: .homebrew(page),
                                title: page.title,
                                systemImage: page.systemImage,
                                selection: $model.selectedDestination
                            )
                        }
                    }

                    SidebarGroup(
                        title: "Node",
                        systemImage: "shippingbox",
                        isExpanded: $nodeExpanded
                    ) {
                        ForEach(NodePage.allCases) { page in
                            SidebarDestinationRow(
                                destination: .node(page),
                                title: page.title,
                                systemImage: page.systemImage,
                                selection: $model.selectedDestination
                            )
                        }
                    }

                    SidebarGroup(
                        title: "Shell",
                        systemImage: "terminal",
                        isExpanded: $shellExpanded
                    ) {
                        ForEach(ShellPage.allCases) { page in
                            SidebarDestinationRow(
                                destination: .shell(page),
                                title: page.title,
                                systemImage: page.systemImage,
                                selection: $model.selectedDestination
                            )
                        }
                    }

                    Divider()
                        .padding(.vertical, 6)

                    SidebarDestinationRow(
                        destination: .activity,
                        title: "操作记录",
                        systemImage: "clock.arrow.circlepath",
                        selection: $model.selectedDestination
                    )
                }
                .padding(8)
            }
            .scrollIndicators(.hidden)
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            selectedPage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(model.selectedDestination.navigationTitle)
                .navigationSubtitle(navigationSubtitle)
                .overlay(alignment: .top) {
                    Divider()
                }
                .toolbar {
                    ToolbarItem {
                        if model.isRefreshing || model.isHomebrewWorking {
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
        let time = refreshedAt.formatted(date: .omitted, time: .standard)
        return "\(model.selectedDestination.subtitle)（最后刷新：\(time)）"
    }

    @ViewBuilder
    private var selectedPage: some View {
        switch model.selectedDestination {
        case .overview:
            OverviewView(model: model)
        case .homebrew(let page):
            HomebrewView(model: model, page: page)
        case .node(let page):
            NodeView(model: model, page: page)
        case .shell(let page):
            ShellView(model: model, page: page)
        case .activity:
            ActivityView(model: model)
        }
    }
}

private struct SidebarDestinationRow: View {
    let destination: AppDestination
    let title: String
    let systemImage: String
    @Binding var selection: AppDestination

    private var isSelected: Bool {
        selection == destination
    }

    var body: some View {
        Button {
            selection = destination
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(isSelected ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct SidebarGroup<Content: View>: View {
    let title: String
    let systemImage: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                content()
            }
            .padding(.leading, 22)
            .padding(.top, 2)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.headline)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

enum AppRuntime {
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
