import SwiftUI

struct ShellTaskConfirmation: View {
    let plan: ShellActionPlan
    let cancel: () -> Void
    let confirm: () async -> String?

    @State private var isRunning = false
    @State private var hasFinished = false
    @State private var errorMessage: String?

    var body: some View {
        MaintenanceModalFrame(
            title: title,
            systemImage: systemImage,
            tint: .blue,
            width: 440
        ) {
            if isRunning {
                Text("Running").foregroundStyle(.secondary)
            } else if hasFinished {
                Text(errorMessage == nil ? LocalizedStringResource("Completed") : LocalizedStringResource("Operation Failed"))
                    .foregroundStyle(errorMessage == nil ? .green : .orange)
            } else {
                Text("Terminal").foregroundStyle(.secondary)
            }
        } content: {
            if isRunning {
                MaintenanceLoadingState(title: runningMessage)
            } else if hasFinished {
                HStack(alignment: errorMessage == nil ? .center : .top, spacing: 10) {
                    Image(systemName: errorMessage == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(errorMessage == nil ? .green : .orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(errorMessage == nil ? LocalizedStringResource("All actions finished successfully.") : LocalizedStringResource("Operation Failed"))
                            .font(.body.weight(.medium))
                        if let errorMessage {
                            Text(verbatim: errorMessage)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            } else {
                let targetPath = plan.payload.targetPath
                VStack(alignment: .leading, spacing: 10) {
                    if plan.request.action == .installOhMyZsh {
                        Text("Download the official Oh My Zsh installer to \(targetPath). Keep the existing .zshrc and login shell; do not launch a new shell.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    } else if plan.request.action == .tidy {
                        Text("Store ZSH_COMPDUMP in ~/.zshenv (~/.cache/zsh), clean stale zcompdump caches, and move historical backups into \(targetPath).")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if !plan.candidates.isEmpty {
                            MaintenanceDetailWell(maxHeight: 200) {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(plan.candidates, id: \.self) {
                                        Text($0).font(.callout.monospaced()).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    } else {
                        Text("Download this GitHub repository and enable the plugin. Back up .zshrc and validate its syntax.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        MaintenanceDetailWell(maxHeight: 200) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(plan.request.subject).font(.callout.monospaced()).textSelection(.enabled)
                                LabeledContent("Target Path") {
                                    Text(plan.payload.targetPath).font(.callout.monospaced()).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if !plan.canExecute {
                        Label { Text(plan.blockingMessage) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                            .font(.callout)
                    }
                }
            }
        } footer: {
            Spacer()
            if isRunning {
                Text(runningMessage).foregroundStyle(.secondary)
            } else if hasFinished {
                Button("OK", action: cancel)
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button {
                    guard !isRunning else { return }
                    isRunning = true
                    Task {
                        errorMessage = await confirm()
                        isRunning = false
                        hasFinished = true
                    }
                } label: { Text(title) }
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
                    .disabled(!plan.canExecute)
            }
        }
        .interactiveDismissDisabled(isRunning)
    }

    private var systemImage: String {
        switch plan.request.action {
        case .installOhMyZsh: "terminal.fill"
        case .tidy: "sparkles"
        default: "puzzlepiece.extension.fill"
        }
    }

    private var title: LocalizedStringResource {
        switch plan.request.action {
        case .installOhMyZsh: LocalizedStringResource("Install Oh My Zsh")
        case .tidy: LocalizedStringResource("Tidy Zsh Files")
        default: LocalizedStringResource("Install Terminal Plugin")
        }
    }

    private var runningMessage: LocalizedStringResource {
        switch plan.request.action {
        case .installOhMyZsh: LocalizedStringResource("Installing Oh My Zsh…")
        case .tidy: LocalizedStringResource("Tidying Zsh Files…")
        default: LocalizedStringResource("Installing Terminal Plugin…")
        }
    }
}
