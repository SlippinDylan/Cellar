import SwiftUI

struct ShellMaintenancePage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ShellPageContainer(model: model) { shell in
            VStack {
                ContentUnavailableView(
                    "整理 Zsh 文件",
                    systemImage: "folder.badge.gearshape",
                    description: Text("把 zcompdump 和历史备份移动到 ~/.zsh，写入受管理的 ZSH_COMPDUMP 配置，并在修改前备份 .zshrc。")
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.prepareShellAction(.init(action: .tidy, subject: "zsh-files")) }
                    } label: {
                        Label("准备整理", systemImage: "folder.badge.gearshape")
                    }
                    .help("准备整理 Zsh 文件")
                    .disabled(model.isShellWorking || !shell.zshrcExists)
                }
            }
        }
    }
}
