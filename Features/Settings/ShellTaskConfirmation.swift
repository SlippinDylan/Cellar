import SwiftUI

struct ShellTaskConfirmation: View {
    let plan: ShellActionPlan
    let cancel: () -> Void
    let confirm: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if plan.request.action == .installOhMyZsh {
                        Text("Download the official Oh My Zsh installer. Keep the existing .zshrc and login shell; do not launch a new shell.")
                    } else if plan.request.action == .tidy {
                        Text("Store ZSH_COMPDUMP in ~/.zshenv (~/.cache/zsh), clean stale zcompdump caches, and move historical backups into ~/.zsh/backups.")
                        ForEach(plan.candidates, id: \.self) { Text($0).textSelection(.enabled) }
                    } else {
                        Text(plan.request.subject).textSelection(.enabled)
                        Text("Download this GitHub repository and enable the plugin. Back up .zshrc and validate its syntax.")
                    }
                    Text(plan.payload.targetPath).textSelection(.enabled)
                    if !plan.canExecute { Label { Text(plan.blockingMessage) } icon: { Image(systemName: "exclamationmark.triangle") } }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 280)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button { confirm() } label: { Text(title) }.disabled(!plan.canExecute)
            }
        }.padding(24).constrainedSheetWidth(540)
    }
    private var title: LocalizedStringResource {
        switch plan.request.action {
        case .installOhMyZsh: LocalizedStringResource("Install Oh My Zsh")
        case .tidy: LocalizedStringResource("Tidy Zsh Files")
        default: LocalizedStringResource("Install Terminal Plugin")
        }
    }
}
