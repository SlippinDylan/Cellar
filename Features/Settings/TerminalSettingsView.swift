import SwiftUI

struct TerminalSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var plugins = Set<String>()
    @State private var theme = ""
    @State private var pluginURL = ""
    @State private var showsPluginSelection = false
    @State private var showsPluginInstallation = false
    @State private var submittedPluginURL: URL?
    @State private var retainedConfigPlan: ShellConfigurationPlan?
    var body: some View {
        SettingsPage(fillsViewport: true) {
            if let shell = model.shell, !shell.ohMyZshInstalled {
                SettingsSection(title: "Oh My Zsh", website: CatalogWebsites.url(host: "github.com", path: "/ohmyzsh/ohmyzsh"), websiteTitle: "Oh My Zsh Project") {
                    HStack {
                        Text("Oh My Zsh is not installed.")
                        Spacer()
                        Button("Install Oh My Zsh") { Task { await model.prepareShellAction(.init(action: .installOhMyZsh)) } }
                            .disabled(model.isBusy)
                    }
                }
            }
            if let shell = model.shell, shell.ohMyZshInstalled {
                SettingsSection(
                    title: "Plugins and Theme",
                    website: CatalogWebsites.url(host: "github.com", path: "/ohmyzsh/ohmyzsh"),
                    websiteTitle: "Oh My Zsh Project",
                    footer: "Apply saves the selected plugins and theme."
                ) {
                    HStack {
                        Text("Local Theme")
                        Spacer()
                        Picker("Local Theme", selection: $theme) {
                            if theme.isEmpty {
                                Text("Choose a Local Theme").tag("")
                            } else if !shell.availableThemes.contains(theme) {
                                Text(verbatim: theme).tag(theme)
                            }
                            ForEach(shell.availableThemes, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .buttonStyle(.automatic)
                        .buttonBorderShape(.roundedRectangle)
                        .controlSize(.regular)
                        .frame(width: 175, alignment: .trailing)
                        .disabled(model.isBusy)
                    }
                    .frame(minHeight: AppLayout.minimumControlRowHeight)
                    Divider()
                    HStack {
                        Text("Plugins")
                        Spacer()
                        Button {
                            showsPluginSelection.toggle()
                        } label: {
                            HStack {
                                Text("\(plugins.count) Selected Plugins")
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption.weight(.semibold))
                            }
                            .frame(width: 155, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .buttonSizing(.flexible)
                        .buttonBorderShape(.roundedRectangle)
                        .controlSize(.regular)
                        .frame(width: 175, alignment: .trailing)
                        .disabled(model.isBusy)
                        .accessibilityLabel(Text("Plugins"))
                        .popover(isPresented: $showsPluginSelection, arrowEdge: .bottom) {
                            pluginSelection(shell)
                        }
                    }
                    .frame(minHeight: AppLayout.minimumControlRowHeight)
                    Divider()
                    HStack(alignment: .center, spacing: 24) {
                        Spacer(minLength: 0)
                        Button("Apply") { Task { await model.prepareTerminalConfiguration(plugins: plugins.sorted(), theme: theme) } }
                            .disabled(model.isBusy || !hasChanges(shell) || (!shell.availableThemes.contains(theme) && theme != shell.currentTheme))
                    }
                    .frame(minHeight: AppLayout.minimumControlRowHeight)
                }
                SettingsSection(title: "Custom Plugins") {
                    HStack {
                        Text("GitHub Repository URL")
                        Spacer()
                        Button("Install from GitHub") { showsPluginInstallation = true }
                            .disabled(model.isBusy)
                    }
                    .frame(minHeight: AppLayout.minimumControlRowHeight)
                }
            }
            SettingsSection(
                title: "Terminal Maintenance",
                footer: "Move the listed Zsh completion files and historical backups into .zsh. Back up .zshrc before updating its managed completion location."
            ) {
                HStack(spacing: 24) {
                    Text("Zsh Files")
                    Spacer(minLength: 0)
                    Button("Tidy Zsh Files") { Task { await model.prepareShellAction(.init(action: .tidy, subject: "zsh-files")) } }
                        .disabled(model.shell?.zshrcExists != true || model.isBusy)
                        .fixedSize()
                }
                .frame(minHeight: AppLayout.minimumControlRowHeight)
            }
            Spacer(minLength: 0)
            EnvironmentFooterView {
                if let shell = model.shell {
                    LabeledContent("Oh My Zsh", value: String(localized: shell.ohMyZshInstalled ? "Installed" : "Not Installed"))
                } else {
                    Text("Terminal State Unavailable")
                }
            }
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .onAppear { synchronize() }
        .onChange(of: model.shell?.activePlugins) { previous, current in
            let matchesPrevious = previous == nil ? plugins.isEmpty : plugins == Set(previous ?? []).union(["git"])
            if matchesPrevious, let current { plugins = Set(current).union(["git"]) }
        }
        .onChange(of: model.shell?.currentTheme) { previous, current in
            let matchesPrevious = previous == nil ? theme.isEmpty : theme == previous
            if matchesPrevious, let current { theme = current }
        }
        .sheet(isPresented: $showsPluginInstallation, onDismiss: prepareSubmittedPlugin) {
            pluginInstallationSheet
        }
        .modifier(ProviderTaskPresentation(model: model, surface: .terminal))
        .onChange(of: model.terminalConfigurationPlan?.id) { _, _ in
            if let plan = model.terminalConfigurationPlan { retainedConfigPlan = plan }
        }
        .sheet(item: Binding(get: { retainedConfigPlan ?? model.terminalConfigurationPlan }, set: {
            if $0 == nil {
                retainedConfigPlan = nil
                model.terminalConfigurationPlan = nil
                model.dismissShellFeedback()
            }
        })) { plan in
            TerminalApplyConfirmation(plan: plan, cancel: {
                retainedConfigPlan = nil
                model.terminalConfigurationPlan = nil
                model.dismissShellFeedback()
            }, confirm: {
                retainedConfigPlan = plan
                model.dismissShellFeedback()
                await model.executeTerminalConfiguration(plan)
                return (model.terminalConfigurationResult, model.shellOperationError)
            })
            .onAppear { model.beginModalPresentation() }
            .onDisappear { model.endModalPresentation() }
        }
    }
    private var pluginInstallationSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Install from GitHub").font(.title2.bold())
            SettingsTextField(title: "GitHub Repository URL", text: $pluginURL, prompt: "https://github.com/owner/repository")
            if !pluginURL.isEmpty && TerminalPluginSource.repository(pluginURL) == nil {
                Text("Use an HTTPS GitHub repository URL without credentials, query, or fragment.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { showsPluginInstallation = false }
                    .keyboardShortcut(.cancelAction)
                Button("Install Plugin") {
                    guard let url = TerminalPluginSource.repository(pluginURL) else { return }
                    submittedPluginURL = url
                    showsPluginInstallation = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(TerminalPluginSource.repository(pluginURL) == nil || model.isBusy)
            }
        }
        .padding(24)
        .constrainedSheetWidth(500)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
    }

    private func prepareSubmittedPlugin() {
        guard let url = submittedPluginURL else { return }
        submittedPluginURL = nil
        Task { await model.prepareShellAction(.init(action: .installPlugin, subject: url.absoluteString)) }
    }

    private func synchronize() { if let shell = model.shell { plugins = Set(shell.activePlugins).union(["git"]); theme = shell.currentTheme } }
    private func pluginNames(_ shell: ShellStatus) -> [String] {
        Array(Set(shell.defaultPluginNames + shell.installedCustomPlugins)).sorted()
    }
    private func pluginSelection(_ shell: ShellStatus) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(plugins.sorted(), id: \.self) { name in
                    pluginOption(name, shell: shell)
                }
                Divider().padding(.vertical, 6)
                ForEach(pluginNames(shell).filter { !plugins.contains($0) }, id: \.self) { name in
                    pluginOption(name, shell: shell)
                }
            }
            .padding(12)
        }
        .frame(width: 480, height: 360)
        .controlSize(.regular)
        .disabled(model.isBusy)
        .onExitCommand { showsPluginSelection = false }
    }

    private func pluginOption(_ name: String, shell: ShellStatus) -> some View {
        Toggle(isOn: Binding(
            get: { plugins.contains(name) },
            set: { enabled in
                if enabled { plugins.insert(name) } else { plugins.remove(name) }
            }
        )) {
            HStack(spacing: 20) {
                Text(verbatim: name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Group {
                    if shell.installedCustomPlugins.contains(name) {
                        Text("Installed Custom Plugin")
                    } else if shell.defaultPluginNames.contains(name) {
                        Text("Built-in Oh My Zsh Plugin")
                    } else {
                        Text("Not Installed")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize()
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 8)
        .disabled(name == "git")
    }
    private func hasChanges(_ shell: ShellStatus) -> Bool { TerminalConfigurationSelection.hasChanges(plugins: plugins, theme: theme, snapshot: shell) }
}

private struct TerminalApplyConfirmation: View {
    let plan: ShellConfigurationPlan
    let cancel: () -> Void
    let confirm: () async -> (result: ShellConfigurationResult?, refreshError: String?)

    @State private var isRunning = false
    @State private var hasFinished = false
    @State private var result: ShellConfigurationResult?
    @State private var refreshError: String?

    var body: some View {
        MaintenanceModalFrame(
            title: LocalizedStringResource("Apply Terminal Changes"),
            systemImage: "terminal.fill",
            tint: .blue,
            width: 440
        ) {
            if isRunning {
                Text("Running").foregroundStyle(.secondary)
            } else if hasFinished {
                let succeeded = refreshError == nil && result?.status == .succeeded
                Text(succeeded ? LocalizedStringResource("Terminal Changes Applied") : LocalizedStringResource("Terminal Changes Incomplete"))
                    .foregroundStyle(succeeded ? .green : .orange)
            } else {
                Text("Plugins and Theme").foregroundStyle(.secondary)
            }
        } content: {
            if isRunning {
                MaintenanceLoadingState(title: LocalizedStringResource("Running"))
            } else if hasFinished {
                if let refreshError {
                    Label {
                        Text(verbatim: refreshError).textSelection(.enabled)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                if let result {
                    MaintenanceDetailWell(maxHeight: 220) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(result.stepOutcomes.enumerated()), id: \.offset) { _, outcome in
                                Label {
                                    Text(outcome.step.title)
                                    Text(outcome.status.activityTitle).foregroundStyle(.secondary)
                                } icon: {
                                    Image(systemName: outcome.status.systemImage)
                                        .foregroundStyle(outcome.status == .succeeded ? .green : .orange)
                                }
                            }
                        }
                    }
                } else {
                    Label { Text(ActivityItemReason.stateUnavailable.message) } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Back up .zshrc, update its managed plugin and theme sections, and check syntax. The login shell stays unchanged.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    MaintenanceDetailWell(maxHeight: 220) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(plan.plans) { change in
                                LabeledContent(change.request.action == .setPlugins ? LocalizedStringResource("Plugins") : LocalizedStringResource("Local Theme")) {
                                    Text(change.request.subject).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if !plan.canExecute {
                        Label("This action is blocked by the current environment. Refresh and review the protected target or file type.", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
            }
        } footer: {
            Spacer()
            if isRunning {
                Text("Running").foregroundStyle(.secondary)
            } else if hasFinished {
                Button("OK", action: cancel)
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Apply") {
                    guard !isRunning else { return }
                    isRunning = true
                    Task {
                        let completion = await confirm()
                        result = completion.result
                        refreshError = completion.refreshError
                        isRunning = false
                        hasFinished = true
                    }
                }
                .buttonStyle(.glassProminent)
                .tint(.blue)
                .disabled(!plan.canExecute)
            }
        }
        .interactiveDismissDisabled(isRunning)
    }
}
