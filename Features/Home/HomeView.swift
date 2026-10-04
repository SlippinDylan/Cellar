import SwiftUI

private enum HomeSetupRequest: Equatable {
    case commandLineTools, homebrew, finishInstaller
}

struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var dashboard: HomeDashboardModel
    @State private var setupRequest: HomeSetupRequest?

    init(model: AppModel) {
        self.model = model
        dashboard = model.homeDashboard
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Local tools and available updates.").foregroundStyle(.secondary)
                if model.isRefreshing {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Reading Local Environment")
                    }
                } else if model.refreshedAt == nil {
                    Text("Refresh to read the local environment.")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), alignment: .top)], alignment: .leading, spacing: 16) {
                    homebrewSection
                    nodeSection
                }
            }
            .padding(20)
        }
        .controlSize(.regular)
        .task(id: model.isRefreshing ? nil : model.refreshedAt) {
            guard !model.isRefreshing else { return }
            await model.refreshHomeBackground(after: model.refreshedAt)
        }
        .task(id: setupRequest) {
            guard let request = setupRequest else { return }
            switch request {
            case .commandLineTools: await dashboard.requestCommandLineTools(installation: .commandLineToolsRequired)
            case .homebrew: await dashboard.openHomebrewInstaller(installation: installation)
            case .finishInstaller:
                if await dashboard.finishInstallerHandoff() { await model.refresh() }
            }
            setupRequest = nil
        }
    }

    private var installation: HomebrewInstallationState {
        dashboard.installationState(homebrew: model.homebrew, readFailed: model.homebrewRefreshFailed, hasRefreshed: model.refreshedAt != nil)
    }

    private var homebrewSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                commandLineToolsStatus
                HomeOnlineVersionRow(title: "Homebrew", currentVersion: model.homebrew?.version.map(HomeVersion.normalized), state: dashboard.onlineVersion(for: .homebrew), checkedAt: dashboard.onlineCheckedAt[.homebrew])
                if let snapshot = model.homebrew?.snapshot {
                    let summary = HomebrewDashboardSummary(snapshot: snapshot)
                    if let count = summary.formulaCount { countRow("Formula", count) }
                    if let count = summary.caskCount { countRow("Cask", count) }
                    if summary.formulaCount == 0 && summary.caskCount == 0 { Text("No Homebrew packages installed.") }
                    packageUpdates(summary.updates, state: model.homebrewUpdateState, checkedAt: model.homebrewOutdatedCheckedAt)
                    if summary.hasPartialFailure { inlineWarning("Some Homebrew information could not be read.") }
                }
                if model.homebrewRefreshFailed { inlineWarning("Local Homebrew refresh failed. Previously read information is retained.") }
                homebrewSetup
                HomeTimestampRow(title: "Local Refresh", date: model.homebrewRefreshedAt)
                Link("Homebrew Website", destination: dashboard.officialHomebrewURL)
                    .frame(minHeight: 28)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        } label: {
            Label("Homebrew", systemImage: "mug").font(.title3)
        }
    }

    private var nodeSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if let snapshot = model.node {
                    let summary = NodeDashboardSummary(snapshot: snapshot)
                    HomeOnlineVersionRow(title: "Node", currentVersion: summary.nodeVersion, state: dashboard.onlineVersion(for: .node), checkedAt: dashboard.onlineCheckedAt[.node])
                    HomeOnlineVersionRow(title: "npm", currentVersion: summary.npmVersion, state: dashboard.onlineVersion(for: .npm), checkedAt: dashboard.onlineCheckedAt[.npm])
                    if let version = summary.defaultVersion { Text("nvm Default: \(version)") }
                    else { Text("nvm Default: Unresolved").foregroundStyle(.secondary) }
                    Text("Current Node Environment: \(summary.nodeVersion)")
                    countRow("Global npm Packages in This Environment", summary.packageCount)
                    if summary.packageCount == 0 { Text("No global npm packages in this Node environment.") }
                    packageUpdates(summary.updates, state: model.nodeUpdateState, checkedAt: model.nodeOutdatedCheckedAt)
                } else {
                    Text(model.refreshedAt == nil ? LocalizedStringResource("Node Environment Not Read") : LocalizedStringResource("Node Environment Unavailable"))
                    Text("Select an installed Node environment in Tools or follow the official guide.")
                    Button("Open Runtime Tools") { model.openRuntimeTools() }
                    HomeOnlineVersionRow(title: "Node", currentVersion: nil, state: dashboard.onlineVersion(for: .node), checkedAt: dashboard.onlineCheckedAt[.node])
                    HomeOnlineVersionRow(title: "npm", currentVersion: nil, state: dashboard.onlineVersion(for: .npm), checkedAt: dashboard.onlineCheckedAt[.npm])
                }
                if model.nodeRefreshFailed { inlineWarning("Local Node refresh failed. Previously read information is retained.") }
                if dashboard.nvmInstalled == true || model.node?.summary.nvmLoaded == true { Label("nvm Available", systemImage: "checkmark.circle") }
                else if dashboard.nvmInstalled == false {
                    Label("nvm Not Installed", systemImage: "minus.circle")
                    Text("Install nvm using the official guide, then refresh the local environment.")
                    Button("Open Environment Setup") { model.selectedToolsCategory = .environment; model.selectedDestination = .tools }
                }
                HomeOnlineVersionRow(title: "nvm", currentVersion: nil, state: dashboard.onlineVersion(for: .nvm), checkedAt: dashboard.onlineCheckedAt[.nvm])
                HomeTimestampRow(title: "Local Refresh", date: model.nodeRefreshedAt)
                Link("nvm Installation Guide", destination: CatalogWebsites.nvm)
                    .frame(minHeight: 28)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        } label: {
            Label("Node, npm & nvm", systemImage: "shippingbox").font(.title3)
        }
    }

    @ViewBuilder private var commandLineToolsStatus: some View {
        switch dashboard.commandLineTools {
        case .notLoaded: Text("Command Line Tools Not Checked").foregroundStyle(.secondary)
        case .loading: Text("Checking Command Line Tools").foregroundStyle(.secondary)
        case .available(.installed): Label("Command Line Tools Installed", systemImage: "checkmark.circle")
        case .available(.notInstalled):
            Label("Command Line Tools Required", systemImage: "exclamationmark.triangle")
            Text("Homebrew needs Apple’s Command Line Tools. macOS handles the installation.")
            Button("Install Command Line Tools…") { setupRequest = .commandLineTools }
                .disabled(model.isBusy)
        case .failed: inlineWarning("Command Line Tools could not be checked. Refresh to try again.")
        }
    }

    @ViewBuilder private var homebrewSetup: some View {
        if dashboard.installerHandoffPending {
            Text("Installer Opened. Complete or cancel the installation in macOS Installer, then recheck. Opening Installer does not confirm installation.")
            Button("Finished in Installer — Recheck") { setupRequest = .finishInstaller }
                .disabled(model.isBusy)
        } else if installation == .notInstalled {
            Label("Homebrew Not Installed", systemImage: "minus.circle")
            Text("Cellar verifies the official signed package. macOS Installer handles authorization and installation.")
            Button("Open Homebrew Installer…") { setupRequest = .homebrew }
                .disabled(model.isBusy)
        } else if case .unavailable = installation {
            inlineWarning("Homebrew is unavailable. Refresh or use the official recovery guidance; existing files will not be replaced.")
        }
        switch dashboard.setupState {
        case .requestingCommandLineTools, .preparingInstaller:
            HStack {
                ProgressView().controlSize(.small)
                Text("Preparing System Installation")
            }
        case .commandLineToolsRequested: Text("Installation requested. Finish in the system dialog, then refresh.")
        case .failed(let failure): inlineWarning(failure.message)
        case .idle, .installerOpened: EmptyView()
        }
    }

    @ViewBuilder private func updatePreview(_ preview: HomeUpdatePreview?) -> some View {
        if let preview {
            countRow("Updates", preview.totalCount)
            if preview.totalCount == 0 { Text("No updates reported by the last check.").foregroundStyle(.secondary) }
            else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(preview.names.enumerated()), id: \.offset) { _, name in
                        Text(name).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if preview.remainingCount > 0 {
                        let count = String(preview.remainingCount)
                        Text("And \(count) More").foregroundStyle(.secondary)
                    }
                }
                Button("View Updates") { model.selectedDestination = .updates }
            }
        } else { inlineWarning("Updates could not be checked. Local information is still available.") }
    }

    @ViewBuilder private func packageUpdates(_ preview: HomeUpdatePreview?, state: HomePackageUpdateState, checkedAt: Date?) -> some View {
        switch state {
        case .notLoaded: Text("Package Updates Not Checked").foregroundStyle(.secondary)
        case .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text("Checking Package Updates")
            }
        case .available: updatePreview(preview)
        case .failed: inlineWarning("Updates could not be checked. Local information is still available.")
        }
        HomeTimestampRow(title: "Package Updates Check", date: checkedAt)
    }

    private func countRow(_ title: LocalizedStringResource, _ count: Int) -> some View {
        LabeledContent { Text(count, format: .number) } label: { Text(title) }
    }

    private func inlineWarning(_ message: LocalizedStringResource) -> some View {
        Label { Text(message) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct HomeOnlineVersionRow: View {
    let title: LocalizedStringResource
    let currentVersion: String?
    let state: OnlineVersionState
    let checkedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                if let currentVersion { Text(HomeVersion.normalized(currentVersion)).textSelection(.enabled) }
                else { Text("Local Version Unavailable").foregroundStyle(.secondary) }
            } label: { Text(title) }
            switch state {
            case .notLoaded: Text("Online Version Not Checked").foregroundStyle(.secondary)
            case .loading:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking Official Version").foregroundStyle(.secondary)
                }
            case .available(let version):
                Text("Latest: \(version)")
                if let currentVersion { CatalogVersionStatusView(status: SemanticVersionStatus(current: HomeVersion.normalized(currentVersion), available: version)) }
            case .unavailable(let reason):
                Label(reason == "offline" ? LocalizedStringResource("Online Check Unavailable — Offline") : LocalizedStringResource("Online Version Check Failed"), systemImage: "exclamationmark.triangle")
            }
            HomeTimestampRow(title: "Online Check", date: checkedAt)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct HomeTimestampRow: View {
    let title: LocalizedStringResource
    let date: Date?

    var body: some View {
        if let date {
            LabeledContent { Text(date, format: .dateTime.month(.abbreviated).day().hour().minute()) } label: { Text(title) }
                .foregroundStyle(.secondary)
        }
    }
}

extension HomeSetupFailure {
    var message: LocalizedStringResource {
        switch self {
        case .commandLineTools: LocalizedStringResource("Command Line Tools installation could not be requested. Use Apple’s official guide or refresh and try again.")
        case .homebrew(let failure):
            switch failure {
            case .releaseMetadata: LocalizedStringResource("The official Homebrew installer release could not be verified.")
            case .digestMissing: LocalizedStringResource("The official release does not provide the required SHA-256. The installer was not opened.")
            case .digestInvalid: LocalizedStringResource("The official SHA-256 is invalid. The installer was not opened.")
            case .digestMismatch: LocalizedStringResource("The downloaded installer does not match the official SHA-256. The installer was not opened.")
            case .download: LocalizedStringResource("The Homebrew installer download failed. The installer was not opened.")
            case .packageSignature: LocalizedStringResource("The package signature could not be verified. The installer was not opened.")
            case .gatekeeper: LocalizedStringResource("Gatekeeper did not approve the package. The installer was not opened.")
            case .systemOpen: LocalizedStringResource("macOS Installer could not be opened. Use the official Homebrew website for guidance.")
            case .temporaryFile: LocalizedStringResource("The installer’s temporary file could not be managed. Use the official Homebrew website for guidance.")
            case .installationInProgress: LocalizedStringResource("A Homebrew installer handoff is still pending. Finish it before starting another.")
            case .commandLineToolsRequired: LocalizedStringResource("Command Line Tools are missing or could not be verified. The Homebrew installer was not opened.")
            case .installationTarget: LocalizedStringResource("The Homebrew installation location is occupied or could not be verified. The installer was not opened.")
            }
        }
    }
}
