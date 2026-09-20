import SwiftUI

struct ShellPageContainer<Content: View>: View {
    @ObservedObject var model: AppModel
    @ViewBuilder let content: (ShellStatus) -> Content

    var body: some View {
        if let shell = model.shell {
            content(shell)
        } else if model.isRefreshing {
            PageLoadingView(message: "正在读取 Shell 状态…")
        } else {
            ContentUnavailableView(
                "无法读取 Shell",
                systemImage: "terminal",
                description: Text(model.errorMessages.first(where: { $0.hasPrefix("Shell") }) ?? "请刷新后重试")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension ShellAction {
    var title: String {
        switch self {
        case .installOhMyZsh: "安装 Oh My Zsh"
        case .installPlugin: "安装插件"
        case .setPlugins: "应用插件配置"
        case .switchTheme: "切换主题"
        case .tidy: "整理 Zsh 文件"
        }
    }

    var isDestructive: Bool { self == .tidy }
}
