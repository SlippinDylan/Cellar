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
                        Text("Move the listed completion files and historical backups into .zsh. The current .zshrc is backed up before its managed completion location changes.")
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
        }.padding(24).frame(width: 540)
    }
    private var title: LocalizedStringResource {
        switch plan.request.action {
        case .installOhMyZsh: LocalizedStringResource("Install Oh My Zsh")
        case .tidy: LocalizedStringResource("Tidy Zsh Files")
        default: LocalizedStringResource("Install Terminal Plugin")
        }
    }
}
