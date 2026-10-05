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
                homebrewSection
                nodeSection
                terminalEnvironmentSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentMargins(20, for: .scrollContent)
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
        VStack(alignment: .leading, spacing: 12) {
            Label("Homebrew", systemImage: "mug")
                .font(.title3)
            let summary = model.homebrew?.snapshot.map(HomebrewDashboardSummary.init)
            homebrewMetrics(summary)
            if summary?.hasPartialFailure == true { inlineWarning("Some Homebrew information could not be read.") }
            if model.homebrewUpdateState == .failed { inlineWarning("Updates could not be checked. Local information is still available.") }
            if model.homebrewRefreshFailed { inlineWarning("Local Homebrew refresh failed. Previously read information is retained.") }
            homebrewSetup
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var nodeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Node", systemImage: "shippingbox").font(.title3)
            nodeMetrics(model.node.map(NodeDashboardSummary.init))
            if model.nodeUpdateState == .failed { inlineWarning("Updates could not be checked. Local information is still available.") }
            if model.nodeRefreshFailed { inlineWarning("Local Node refresh failed. Previously read information is retained.") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var terminalEnvironmentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Terminal Environment", systemImage: "terminal")
                .font(.title3)
            terminalEnvironmentMetrics
            terminalEnvironmentSetup
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func homebrewMetrics(_ summary: HomebrewDashboardSummary?) -> some View {
        HStack(spacing: 0) {
            let hasHomebrewUpdate = homebrewHasUpdate(summary)
            StatusMetric(
                title: String(localized: "Homebrew"),
                value: homebrewVersion(summary),
                valueSystemImage: hasHomebrewUpdate ? "arrow.up.circle.fill" : nil,
                titleLink: dashboard.officialHomebrewURL,
                titleLinkLabel: "Homebrew Website",
                systemImage: "mug.fill",
                tint: summary == nil ? .secondary : .blue
            )
            StatusMetricDivider()
            StatusMetric(
                title: String(localized: "Formula"),
                value: metricCount(summary?.formulaCount),
                systemImage: "shippingbox.fill",
                tint: summary?.formulaCount == nil ? .secondary : .blue
            )
            StatusMetricDivider()
            StatusMetric(
                title: String(localized: "Cask"),
                value: metricCount(summary?.caskCount),
                systemImage: "app.grid",
                tint: summary?.caskCount == nil ? .secondary : .purple
            )
            StatusMetricDivider()
            StatusMetric(
                title: String(localized: "Updates"),
                value: updateMetricValue(summary?.updates, state: model.homebrewUpdateState),
                systemImage: "arrow.up.circle.fill",
                tint: updateMetricTint(summary?.updates, state: model.homebrewUpdateState)
            )
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var terminalEnvironmentMetrics: some View {
        HStack(spacing: 0) {
            StatusMetric(
                title: String(localized: "Command Line Tools"),
                value: commandLineToolsValue,
                systemImage: "hammer.fill",
                tint: commandLineToolsTint
            )
            StatusMetricDivider()
            StatusMetric(
                title: String(localized: "Zsh"),
                value: zshVersion,
                systemImage: "terminal.fill",
                tint: model.shell == nil ? .secondary : .blue
            )
            StatusMetricDivider()
            StatusMetric(
                title: String(localized: "Oh My Zsh"),
                value: ohMyZshValue,
                systemImage: "bolt.fill",
                tint: ohMyZshTint
            )
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func nodeMetrics(_ summary: NodeDashboardSummary?) -> some View {
        VStack(spacing: 0) {
            let hasNodeUpdate = summary.map { HomeVersion.hasUpdate(current: $0.nodeVersion, online: dashboard.onlineVersion(for: .node)) } ?? false
            let hasNPMUpdate = summary.map { HomeVersion.hasUpdate(current: $0.npmVersion, online: dashboard.onlineVersion(for: .npm)) } ?? false
            HStack(spacing: 0) {
                StatusMetric(
                    title: String(localized: "Node"),
                    value: summary.map { HomeVersion.display(current: $0.nodeVersion, online: dashboard.onlineVersion(for: .node)) } ?? "—",
                    valueSystemImage: hasNodeUpdate ? "arrow.up.circle.fill" : nil,
                    systemImage: "shippingbox.fill",
                    tint: summary == nil ? .secondary : .green
                )
                StatusMetricDivider()
                StatusMetric(
                    title: String(localized: "npm"),
                    value: summary.map { HomeVersion.display(current: $0.npmVersion, online: dashboard.onlineVersion(for: .npm)) } ?? "—",
                    valueSystemImage: hasNPMUpdate ? "arrow.up.circle.fill" : nil,
                    systemImage: "shippingbox.circle.fill",
                    tint: summary == nil ? .secondary : .red
                )
                StatusMetricDivider()
                StatusMetric(
                    title: String(localized: "Global Packages"),
                    value: metricCount(summary?.packageCount),
                    systemImage: "square.stack.3d.up.fill",
                    tint: summary == nil ? .secondary : .blue
                )
            }

            Divider()
                .padding(.horizontal, 12)

            HStack(spacing: 0) {
                StatusMetric(
                    title: String(localized: "Updates"),
                    value: updateMetricValue(summary?.updates, state: model.nodeUpdateState),
                    systemImage: "arrow.up.circle.fill",
                    tint: updateMetricTint(summary?.updates, state: model.nodeUpdateState)
                )
                StatusMetricDivider()
                StatusMetric(
                    title: String(localized: "nvm"),
                    value: nvmValue,
                    systemImage: "point.3.connected.trianglepath.dotted",
                    tint: nvmTint
                )
                StatusMetricDivider()
                StatusMetric(
                    title: String(localized: "nvm Default"),
                    value: nvmDefaultValue(summary),
                    systemImage: "checkmark.seal.fill",
                    tint: summary?.defaultVersion == nil ? .secondary : .purple
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var commandLineToolsValue: String {
        switch dashboard.commandLineTools {
        case .available(.installed): String(localized: "Installed")
        case .available(.notInstalled): String(localized: "Not Installed")
        case .notLoaded, .loading, .failed: "—"
        }
    }

    private var commandLineToolsTint: Color {
        switch dashboard.commandLineTools {
        case .available(.installed): .green
        case .available(.notInstalled): .orange
        case .notLoaded, .loading, .failed: .secondary
        }
    }

    private var zshVersion: String {
        model.shell?.zshVersion?.replacingOccurrences(of: "zsh ", with: "") ?? "—"
    }

    private var ohMyZshValue: String {
        guard let shell = model.shell else { return "—" }
        return shell.ohMyZshInstalled ? String(localized: "Installed") : String(localized: "Not Installed")
    }

    private var ohMyZshTint: Color {
        guard let shell = model.shell else { return .secondary }
        return shell.ohMyZshInstalled ? .purple : .secondary
    }

    private func homebrewVersion(_ summary: HomebrewDashboardSummary?) -> String {
        guard let current = summary?.version ?? model.homebrew?.version else {
            return installation == .notInstalled ? String(localized: "Not Installed") : "—"
        }
        return HomeVersion.display(current: current, online: dashboard.onlineVersion(for: .homebrew))
    }

    private func homebrewHasUpdate(_ summary: HomebrewDashboardSummary?) -> Bool {
        guard let current = summary?.version ?? model.homebrew?.version else { return false }
        return HomeVersion.hasUpdate(current: current, online: dashboard.onlineVersion(for: .homebrew))
    }

    private var nvmAvailable: Bool {
        dashboard.nvmInstalled == true || model.node?.summary.nvmLoaded == true
    }

    private var nvmValue: String {
        if nvmAvailable { return String(localized: "Installed") }
        if dashboard.nvmInstalled == false { return String(localized: "Not Installed") }
        return "—"
    }

    private var nvmTint: Color {
        if nvmAvailable { return .green }
        return dashboard.nvmInstalled == false ? .orange : .secondary
    }

    private func nvmDefaultValue(_ summary: NodeDashboardSummary?) -> String {
        guard nvmAvailable else { return "—" }
        return summary?.defaultVersion.map(HomeVersion.normalized) ?? String(localized: "Unresolved")
    }

    @ViewBuilder private var terminalEnvironmentSetup: some View {
        switch dashboard.commandLineTools {
        case .available(.notInstalled):
            Text("Homebrew needs Apple’s Command Line Tools. macOS handles the installation.")
            Button("Install Command Line Tools…") { setupRequest = .commandLineTools }
                .disabled(model.isBusy)
        case .failed:
            inlineWarning("Command Line Tools could not be checked. Refresh to try again.")
        case .notLoaded, .loading, .available(.installed):
            EmptyView()
        }

        switch dashboard.setupState {
        case .requestingCommandLineTools:
            HStack {
                ProgressView().controlSize(.small)
                Text("Preparing System Installation")
            }
        case .commandLineToolsRequested:
            Text("Installation requested. Finish in the system dialog, then refresh.")
        case .failed(.commandLineTools):
            inlineWarning(HomeSetupFailure.commandLineTools.message)
        case .idle, .preparingInstaller, .installerOpened, .failed(.homebrew):
            EmptyView()
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
        case .preparingInstaller:
            HStack {
                ProgressView().controlSize(.small)
                Text("Preparing System Installation")
            }
        case .failed(.homebrew(let failure)):
            inlineWarning(HomeSetupFailure.homebrew(failure).message)
        case .idle, .requestingCommandLineTools, .commandLineToolsRequested, .installerOpened, .failed(.commandLineTools):
            EmptyView()
        }
    }

    private func metricCount(_ count: Int?) -> String {
        count?.formatted() ?? "—"
    }

    private func updateMetricValue(_ preview: HomeUpdatePreview?, state: HomePackageUpdateState) -> String {
        guard state == .available, let preview else { return "—" }
        return preview.totalCount.formatted()
    }

    private func updateMetricTint(_ preview: HomeUpdatePreview?, state: HomePackageUpdateState) -> Color {
        guard state == .available, let preview else { return .secondary }
        return preview.totalCount == 0 ? .green : .orange
    }

    private func inlineWarning(_ message: LocalizedStringResource) -> some View {
        Label { Text(message) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
            .fixedSize(horizontal: false, vertical: true)
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
