import SwiftUI

struct ShellExtensionsPage: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case plugins = "插件"
        case themes = "主题"
        var id: Self { self }
    }

    @ObservedObject var model: AppModel
    @State private var mode: Mode = .plugins
    @State private var enabledPlugins = Set<String>()
    @State private var selectedTheme: String?
    @State private var showingPluginInstall = false
    @State private var pluginURL = ""

    var body: some View {
        ShellPageContainer(model: model) { shell in
            VStack(spacing: 0) {
                Picker("扩展类型", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                .padding(.vertical, 16)

                Divider()
                switch mode {
                case .plugins: pluginList(shell)
                case .themes: themeList(shell)
                }
            }
            .onAppear { synchronize(shell) }
            .onChange(of: shell.activePlugins) { _, _ in synchronize(shell) }
            .toolbar { extensionToolbar(shell) }
            .sheet(isPresented: $showingPluginInstall) { pluginInstallSheet }
        }
    }

    private func pluginList(_ shell: ShellStatus) -> some View {
        List {
            Section("已安装插件") {
                ForEach(pluginNames(shell), id: \.self) { name in
                    Toggle(isOn: pluginBinding(name)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name)
                            Text(shell.installedCustomPlugins.contains(name) ? "自定义插件" : "Oh My Zsh 内置插件")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(name == "git")
                }
            }
        }
        .listStyle(.inset)
    }

    private func themeList(_ shell: ShellStatus) -> some View {
        List(shell.availableThemes, id: \.self, selection: $selectedTheme) { theme in
            HStack {
                Text(theme)
                Spacer()
                if theme == shell.currentTheme {
                    Text("当前").foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
    }

    @ToolbarContentBuilder
    private func extensionToolbar(_ shell: ShellStatus) -> some ToolbarContent {
        if mode == .plugins {
            ToolbarItem(placement: .primaryAction) {
                Button { showingPluginInstall = true } label: {
                    Label("安装插件", systemImage: "plus")
                }
                .help("从 GitHub 安装插件")
                .disabled(!shell.ohMyZshInstalled || model.isShellWorking)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button { preparePluginSelection() } label: {
                    Label("应用插件配置", systemImage: "checkmark")
                }
                .help("应用所选插件")
                .disabled(!shell.ohMyZshInstalled || model.isShellWorking)
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                Button { prepareThemeChange() } label: {
                    Label("应用主题", systemImage: "checkmark")
                }
                .help("应用所选主题")
                .disabled(selectedTheme == nil || selectedTheme == shell.currentTheme || model.isShellWorking)
            }
        }
    }

    private var pluginInstallSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("安装 Shell 插件").font(.title2.bold())
            TextField("GitHub HTTPS 地址", text: $pluginURL, prompt: Text("https://github.com/owner/repository"))
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Text("建议")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("zsh-autosuggestions") {
                    pluginURL = "https://github.com/zsh-users/zsh-autosuggestions"
                }
                .controlSize(.small)
                Button("zsh-autocomplete") {
                    pluginURL = "https://github.com/marlonrichert/zsh-autocomplete"
                }
                .controlSize(.small)
                Spacer()
            }
            Text("Cellar 只接受 GitHub HTTPS 地址。下一步会生成包含目标目录的计划，确认后才执行 git clone 和 .zshrc managed block 更新。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { showingPluginInstall = false }.keyboardShortcut(.cancelAction)
                Button("继续") {
                    showingPluginInstall = false
                    Task { await model.prepareShellAction(.init(action: .installPlugin, subject: pluginURL)) }
                }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                .disabled(pluginURL.isEmpty)
            }
        }
        .padding(24).frame(width: 520)
    }

    private func pluginNames(_ shell: ShellStatus) -> [String] {
        Array(Set(shell.activePlugins + shell.installedCustomPlugins + ["git"])).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private func pluginBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { enabledPlugins.contains(name) },
            set: { enabled in
                if enabled { enabledPlugins.insert(name) } else { enabledPlugins.remove(name) }
            }
        )
    }

    private func synchronize(_ shell: ShellStatus) {
        enabledPlugins = Set(shell.activePlugins)
        enabledPlugins.insert("git")
        selectedTheme = shell.currentTheme.isEmpty ? nil : shell.currentTheme
    }

    private func preparePluginSelection() {
        let value = enabledPlugins.sorted().joined(separator: ",")
        Task { await model.prepareShellAction(.init(action: .setPlugins, subject: value)) }
    }

    private func prepareThemeChange() {
        guard let selectedTheme else { return }
        Task { await model.prepareShellAction(.init(action: .switchTheme, subject: selectedTheme)) }
    }
}
