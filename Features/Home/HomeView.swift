import AppKit
import SwiftUI

private enum HomeSetupRequest: Equatable {
    case commandLineTools, homebrew, finishInstaller
}

private enum HomeMetricPalette {
    // Darken official brand hues on light surfaces to keep small symbols legible.
    static let homebrew = adaptive(light: 0x906119, dark: 0xFBB040)
    static let node = adaptive(light: 0x3F873F, dark: 0x6ABF4B)
    static let npm = adaptive(light: 0xC12127, dark: 0xEF6B70)
    static let nvm = adaptive(light: 0x807000, dark: 0xF4DD4B)
    static let zsh = adaptive(light: 0xC0451A, dark: 0xF8855C)
    static let ohMyZsh = adaptive(light: 0x657315, dark: 0xC5D928)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((rgb >> 16) & 0xFF) / 255,
                           green: Double((rgb >> 8) & 0xFF) / 255,
                           blue: Double(rgb & 0xFF) / 255, alpha: 1)
        })
    }
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
            VStack(alignment: .leading, spacing: 20) {
                homebrewSection
                nodeSection
                terminalEnvironmentSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentMargins(AppLayout.spacing, for: .scrollContent)
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
        VStack(alignment: .leading, spacing: AppLayout.spacing) {
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
        VStack(alignment: .leading, spacing: AppLayout.spacing) {
            Label("Node", systemImage: "shippingbox").font(.title3)
            nodeMetrics(model.node.map(NodeDashboardSummary.init))
            if model.nodeUpdateState == .failed { inlineWarning("Updates could not be checked. Local information is still available.") }
            if model.nodeRefreshFailed { inlineWarning("Local Node refresh failed. Previously read information is retained.") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var terminalEnvironmentSection: some View {
        VStack(alignment: .leading, spacing: AppLayout.spacing) {
            Label("Terminal Environment", systemImage: "terminal")
                .font(.title3)
            terminalEnvironmentMetrics
            terminalEnvironmentSetup
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func homebrewMetrics(_ summary: HomebrewDashboardSummary?) -> some View {
        HStack(spacing: 12) {
            let hasHomebrewUpdate = homebrewHasUpdate(summary)
            StatusMetric(
                title: String(localized: "Homebrew"),
                value: homebrewVersion(summary),
                valueSystemImage: hasHomebrewUpdate ? "arrow.up.circle.fill" : nil,
                titleLink: dashboard.officialHomebrewURL,
                titleLinkLabel: "Homebrew Website",
                systemImage: "mug.fill",
                brandAssetName: "HomebrewBrand",
                tint: HomeMetricPalette.homebrew,
                isStandaloneCard: true
            )
            StatusMetric(
                title: String(localized: "Formula"),
                value: metricCount(summary?.formulaCount),
                systemImage: "shippingbox.fill",
                brandAssetName: "FormulaIcon",
                tint: HomeMetricPalette.homebrew,
                isStandaloneCard: true
            )
            StatusMetric(
                title: String(localized: "Cask"),
                value: metricCount(summary?.caskCount),
                systemImage: "app.grid",
                brandAssetName: "CaskIcon",
                tint: HomeMetricPalette.homebrew,
                isStandaloneCard: true
            )
            StatusMetric(
                title: String(localized: "Updates"),
                value: updateMetricValue(summary?.updates, state: model.homebrewUpdateState),
                systemImage: "arrow.up.circle.fill",
                brandAssetName: "UpdatesIcon",
                tint: updateMetricTint(summary?.updates, state: model.homebrewUpdateState),
                isStandaloneCard: true
            )
        }
        .frame(maxWidth: .infinity)
    }

    private var terminalEnvironmentMetrics: some View {
        HStack(spacing: 12) {
            StatusMetric(
                title: String(localized: "Command Line Tools"),
                value: commandLineToolsValue,
                titleLink: CatalogWebsites.commandLineTools,
                titleLinkLabel: "Apple Installation Guide",
                systemImage: "hammer.fill",
                brandAssetName: "CommandLineToolsIcon",
                tint: .blue,
                isStandaloneCard: true
            )
            StatusMetric(
                title: String(localized: "Zsh"),
                value: zshVersion.number,
                valueSuffix: zshVersion.architecture,
                systemImage: "terminal.fill",
                brandAssetName: "ZshBrand",
                tint: HomeMetricPalette.zsh,
                isStandaloneCard: true
            )
            StatusMetric(
                title: String(localized: "Oh My Zsh"),
                value: ohMyZshValue,
                systemImage: "bolt.fill",
                brandAssetName: "OhMyZshBrand",
                tint: HomeMetricPalette.ohMyZsh,
                isStandaloneCard: true
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func nodeMetrics(_ summary: NodeDashboardSummary?) -> some View {
        VStack(spacing: 12) {
            let hasNodeUpdate = summary.map { HomeVersion.hasUpdate(current: $0.nodeVersion, online: dashboard.onlineVersion(for: .node)) } ?? false
            let hasNPMUpdate = summary.map { HomeVersion.hasUpdate(current: $0.npmVersion, online: dashboard.onlineVersion(for: .npm)) } ?? false
            HStack(spacing: 12) {
                StatusMetric(
                    title: String(localized: "Node"),
                    value: summary.map { HomeVersion.display(current: $0.nodeVersion, online: dashboard.onlineVersion(for: .node)) } ?? "—",
                    valueSystemImage: hasNodeUpdate ? "arrow.up.circle.fill" : nil,
                    systemImage: "shippingbox.fill",
                    brandAssetName: "NodeBrand",
                    tint: HomeMetricPalette.node,
                    isStandaloneCard: true
                )
                StatusMetric(
                    title: String(localized: "npm"),
                    value: summary.map { HomeVersion.display(current: $0.npmVersion, online: dashboard.onlineVersion(for: .npm)) } ?? "—",
                    valueSystemImage: hasNPMUpdate ? "arrow.up.circle.fill" : nil,
                    systemImage: "shippingbox.circle.fill",
                    brandAssetName: "NPMBrand",
                    assetSize: 24,
                    tint: HomeMetricPalette.npm,
                    isStandaloneCard: true
                )
                StatusMetric(
                    title: String(localized: "Global Packages"),
                    value: metricCount(summary?.packageCount),
                    systemImage: "square.stack.3d.up.fill",
                    brandAssetName: "GlobalPackagesIcon",
                    tint: HomeMetricPalette.npm,
                    isStandaloneCard: true
                )
            }

            HStack(spacing: 12) {
                StatusMetric(
                    title: String(localized: "Updates"),
                    value: updateMetricValue(summary?.updates, state: model.nodeUpdateState),
                    systemImage: "arrow.up.circle.fill",
                    brandAssetName: "UpdatesIcon",
                    tint: updateMetricTint(summary?.updates, state: model.nodeUpdateState),
                    isStandaloneCard: true
                )
                StatusMetric(
                    title: String(localized: "nvm"),
                    value: nvmValue,
                    titleLink: CatalogWebsites.nvm,
                    titleLinkLabel: "nvm Installation Guide",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    brandAssetName: "NVMBrand",
                    tint: HomeMetricPalette.nvm,
                    isStandaloneCard: true
                )
                StatusMetric(
                    title: String(localized: "nvm Default"),
                    value: nvmDefaultValue(summary),
                    systemImage: "checkmark.seal.fill",
                    brandAssetName: "NVMDefaultIcon",
                    tint: HomeMetricPalette.nvm,
                    isStandaloneCard: true
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var commandLineToolsValue: String {
        switch dashboard.commandLineTools {
        case .available(.installed): String(localized: "Installed")
        case .available(.notInstalled): String(localized: "Not Installed")
        case .notLoaded, .loading, .failed: "—"
        }
    }

    private var zshVersion: (number: String, architecture: String?) {
        let version = model.shell?.zshVersion?.replacingOccurrences(of: "zsh ", with: "") ?? "—"
        guard let suffixStart = version.firstIndex(of: "(") else { return (version, nil) }
        return (String(version[..<suffixStart]).trimmingCharacters(in: .whitespaces), String(version[suffixStart...]))
    }

    private var ohMyZshValue: String {
        guard let shell = model.shell else { return "—" }
        return shell.ohMyZshInstalled ? String(localized: "Installed") : String(localized: "Not Installed")
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
        model.nvmInstalled == true
    }

    private var nvmValue: String {
        if nvmAvailable { return String(localized: "Installed") }
        if model.nvmInstalled == false { return String(localized: "Not Installed") }
        return "—"
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
