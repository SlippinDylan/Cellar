import SwiftUI

struct ShellMaintenancePage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ShellPageContainer(model: model) { shell in
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("受控整理") {
                    OperationRow(
                        title: "整理 Zsh 文件",
                        detail: "移动 zcompdump 和历史备份，写入受管理的 ZSH_COMPDUMP，并在修改前备份 .zshrc。",
                        systemImage: "folder.badge.gearshape",
                        tint: .orange,
                        actionTitle: "准备计划",
                        role: .destructive,
                        isEnabled: !model.isBusy && shell.zshrcExists
                    ) {
                        Task { await model.prepareShellAction(.init(action: .tidy, subject: "zsh-files")) }
                    }
                }

                if !shell.zshrcExists {
                    Label("找不到普通 .zshrc 文件，整理操作已禁用。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            .padding(24)
        }
    }
}
