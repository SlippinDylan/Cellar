import SwiftUI

struct TerminalSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var plugins = Set<String>()
    @State private var theme = ""
    @State private var pluginURL = ""
    @State private var pluginSearch = ""
    var body: some View {
        Form {
            Section {
                if let shell = model.shell {
                    if shell.ohMyZshInstalled { Label("Oh My Zsh Installed", systemImage: "checkmark.circle") }
                    else {
                        Text("Oh My Zsh is not installed.")
                        Button("Install Oh My Zsh…") { Task { await model.prepareShellAction(.init(action: .installOhMyZsh)) } }.disabled(model.isBusy)
                    }
                    Text("Cellar keeps the login shell unchanged. Configuration changes are backed up and checked for syntax.").foregroundStyle(.secondary)
                } else { Text("Terminal State Unavailable") }
            } header: { Text("Oh My Zsh") }
            if let shell = model.shell, shell.ohMyZshInstalled {
                Section {
                    Button("Apply…") { Task { await model.prepareTerminalConfiguration(plugins: plugins.sorted(), theme: theme) } }
                        .disabled(model.isBusy || !hasChanges(shell) || !shell.availableThemes.contains(theme))
                    Text("Apply saves plugin selection and the local theme together. Each completed change is retained if a later change fails.").foregroundStyle(.secondary)
                    Picker("Local Theme", selection: $theme) {
                        if !shell.availableThemes.contains(theme) { Text("Choose a Local Theme").tag("") }
                        ForEach(shell.availableThemes, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Filter Installed Plugins", text: $pluginSearch)
                    ForEach(pluginNames(shell), id: \.self) { name in
                        Toggle(isOn: Binding(get: { plugins.contains(name) }, set: { enabled in if enabled { plugins.insert(name) } else { plugins.remove(name) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name)
                                Text(shell.installedCustomPlugins.contains(name) ? LocalizedStringResource("Installed Custom Plugin") : LocalizedStringResource("Built-in Oh My Zsh Plugin")).foregroundStyle(.secondary)
                            }
                        }.toggleStyle(.checkbox).disabled(name == "git" || model.isBusy)
                    }
                } header: { Text("Plugins and Theme") }
                Section {
                    TextField("GitHub Repository URL", text: $pluginURL, prompt: Text("https://github.com/owner/repository"))
                    if !pluginURL.isEmpty && TerminalPluginSource.repository(pluginURL) == nil { Text("Use an HTTPS GitHub repository URL without credentials, query, or fragment.") }
                    Button("Install Plugin…") {
                        guard let url = TerminalPluginSource.repository(pluginURL) else { return }
                        Task { await model.prepareShellAction(.init(action: .installPlugin, subject: url.absoluteString)) }
                    }.disabled(TerminalPluginSource.repository(pluginURL) == nil || model.isBusy)
                } header: { Text("Add a Custom Plugin") }
            }
            if let result = model.terminalConfigurationResult {
                Label(result.status == .succeeded ? LocalizedStringResource("Terminal Changes Applied") : LocalizedStringResource("Terminal Changes Incomplete"), systemImage: "info.circle")
                ForEach(Array(result.operations.enumerated()), id: \.offset) { _, operation in
                    Text(operation.action == ShellAction.setPlugins.rawValue ? LocalizedStringResource("Plugin Selection Saved") : LocalizedStringResource("Theme Saved"))
                }
                ForEach(Array(result.stepOutcomes.enumerated()), id: \.offset) { _, outcome in
                    Label { Text(outcome.step.title); Text(outcome.status.activityTitle) } icon: { Image(systemName: outcome.status.systemImage) }
                }
            }
        }
        .formStyle(AppFormStyle())
        .onAppear { synchronize() }
        .onChange(of: model.shell?.activePlugins) { previous, current in
            if plugins == Set(previous ?? []).union(["git"]) { plugins = Set(current ?? []).union(["git"]) }
        }
        .onChange(of: model.shell?.currentTheme) { previous, current in if theme == previous { theme = current ?? "" } }
        .modifier(ProviderTaskPresentation(model: model, surface: .terminal))
        .sheet(item: $model.terminalConfigurationPlan) { plan in
            TerminalApplyConfirmation(plan: plan, cancel: { model.terminalConfigurationPlan = nil }, confirm: { Task { await model.executeTerminalConfiguration(plan) } })
        }
    }
    private func synchronize() { if let shell = model.shell { plugins = Set(shell.activePlugins).union(["git"]); theme = shell.currentTheme } }
    private func pluginNames(_ shell: ShellStatus) -> [String] {
        Array(Set(shell.defaultPluginNames + shell.installedCustomPlugins)).sorted().filter { pluginSearch.isEmpty || $0.localizedStandardContains(pluginSearch) }
    }
    private func hasChanges(_ shell: ShellStatus) -> Bool { TerminalConfigurationSelection.hasChanges(plugins: plugins, theme: theme, snapshot: shell) }
}

private struct TerminalApplyConfirmation: View {
    let plan: ShellConfigurationPlan
    let cancel: () -> Void
    let confirm: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Apply Terminal Changes").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Back up .zshrc, update its managed plugin and theme sections, and check syntax. The login shell stays unchanged.")
                    ForEach(plan.plans) { change in
                        LabeledContent(change.request.action == .setPlugins ? LocalizedStringResource("Plugins") : LocalizedStringResource("Local Theme")) { Text(change.request.subject).textSelection(.enabled) }
                    }
                    if !plan.canExecute { Text("This action is blocked by the current environment. Refresh and review the protected target or file type.") }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 280)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Apply", action: confirm).disabled(!plan.canExecute)
            }
        }.padding(24).frame(width: 540)
    }
}
