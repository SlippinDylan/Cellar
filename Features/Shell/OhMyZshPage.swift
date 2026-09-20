import SwiftUI

struct OhMyZshPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ShellPageContainer(model: model) { shell in
            VStack(alignment: .leading, spacing: 16) {
                if shell.ohMyZshInstalled {
                    StatusOverviewCard {
                        StatusMetric(
                            title: "Oh My Zsh",
                            value: "已安装",
                            detail: shell.ohMyZshPath,
                            systemImage: "checkmark.circle.fill",
                            tint: .green
                        )
                    }
                    Text("插件和主题可以在“插件与主题”中管理。Cellar 不切换默认 Shell，也不删除 Oh My Zsh。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    GroupBox("环境引导") {
                        OperationRow(
                            title: "安装 Oh My Zsh",
                            detail: "使用官方固定版本脚本；不切换默认 Shell，不自动打开终端。",
                            systemImage: "bolt.fill",
                            tint: .purple,
                            actionTitle: "生成安装计划",
                            isEnabled: !model.isBusy
                        ) {
                            Task { await model.prepareShellAction(.init(action: .installOhMyZsh)) }
                        }
                    }
                }
                Spacer()
            }
            .padding(24)
        }
    }
}
