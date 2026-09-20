import SwiftUI

struct OhMyZshPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ShellPageContainer(model: model) { shell in
            VStack {
                if shell.ohMyZshInstalled {
                    ContentUnavailableView(
                        "Oh My Zsh 已安装",
                        systemImage: "checkmark.circle",
                        description: Text(shell.ohMyZshPath)
                    )
                } else {
                    ContentUnavailableView(
                        "尚未安装 Oh My Zsh",
                        systemImage: "bolt",
                        description: Text("Cellar 使用 Oh My Zsh 官方固定版本安装脚本，不切换默认 Shell，也不自动打开新的终端。")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                if !shell.ohMyZshInstalled {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await model.prepareShellAction(.init(action: .installOhMyZsh)) }
                        } label: {
                            Label("安装 Oh My Zsh", systemImage: "square.and.arrow.down")
                        }
                        .help("准备安装 Oh My Zsh")
                        .disabled(model.isShellWorking)
                    }
                }
            }
        }
    }
}
