import SwiftUI

struct EnvironmentSetupView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var dashboard: HomeDashboardModel
    init(model: AppModel) { self.model = model; dashboard = model.homeDashboard }
    private var installation: HomebrewInstallationState {
        dashboard.installationState(homebrew: model.homebrew, readFailed: model.homebrewRefreshFailed, hasRefreshed: model.refreshedAt != nil)
    }
    var body: some View {
        Form {
            Section {
                switch dashboard.commandLineTools {
                case .notLoaded: Text("Command Line Tools Not Checked")
                case .loading: EmptyView()
                case .available(.installed): Label("Command Line Tools Installed", systemImage: "checkmark.circle")
                case .available(.notInstalled):
                    Text("Homebrew needs Apple’s Command Line Tools. macOS handles the installation.")
                    Button("Install Command Line Tools…") { Task { await dashboard.requestCommandLineTools(installation: .commandLineToolsRequired) } }
                        .disabled(model.isBusy)
                case .failed: Text("Command Line Tools could not be checked. Refresh to try again.")
                }
                WebsiteLink(destination: CatalogWebsites.commandLineTools, title: LocalizedStringResource("Apple Installation Guide"))
            } header: { Text("Command Line Tools") }
            Section {
                if let version = model.homebrew?.version { Text(version).textSelection(.enabled) }
                if dashboard.installerHandoffPending {
                    Text("Installer Opened. Complete or cancel the installation in macOS Installer, then recheck. Opening Installer does not confirm installation.")
                    Button("Finished in Installer — Recheck") {
                        Task { if await dashboard.finishInstallerHandoff() { await model.refresh(); await dashboard.refreshSetupStatus() } }
                    }.disabled(model.isBusy)
                } else if installation == .notInstalled {
                    Text("Cellar verifies the official signed package. macOS Installer handles authorization and installation.")
                    Button("Open Homebrew Installer…") { Task { await dashboard.openHomebrewInstaller(installation: installation) } }.disabled(model.isBusy)
                } else if case .unavailable = installation {
                    Text("Homebrew is unavailable. Refresh or use the official recovery guidance; existing files will not be replaced.")
                }
                WebsiteLink(destination: CatalogWebsites.homebrew, title: LocalizedStringResource("Homebrew Website"))
            } header: { Text("Homebrew") }
            Section {
                if dashboard.nvmInstalled == true || model.node?.summary.nvmLoaded == true {
                    Label("nvm Available", systemImage: "checkmark.circle")
                    Button("Open Runtime Tools") { model.openRuntimeTools() }
                } else {
                    Text("Install nvm using the official guide, then refresh the local environment.")
                }
                WebsiteLink(destination: CatalogWebsites.nvm, title: LocalizedStringResource("nvm Installation Guide"))
            } header: { Text("nvm") }
            switch dashboard.setupState {
            case .requestingCommandLineTools, .preparingInstaller: ProgressView("Preparing System Installation")
            case .commandLineToolsRequested: Text("Installation requested. Finish in the system dialog, then refresh.")
            case .failed(let failure): Label { Text(failure.message) } icon: { Image(systemName: "exclamationmark.triangle") }
            case .idle, .installerOpened: EmptyView()
            }
            Button("Recheck Setup") { Task { await dashboard.refreshSetupStatus() } }.disabled(model.isBusy)
        }
        .formStyle(AppFormStyle())
        .task { await dashboard.refreshSetupStatus() }
    }
}
