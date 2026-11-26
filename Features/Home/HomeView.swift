import AppKit
import SwiftUI

private enum HomeSetupRequest: Equatable {
    case commandLineTools, homebrew, finishInstaller
}

private enum HomeMetricPalette {
    // Match each card's ambient gradient to its brand icon's dominant hue.
    static let homebrew = adaptive(light: 0xE68A1E, dark: 0xFBB040)
    static let formula = adaptive(light: 0x9344CC, dark: 0xC084FC)
    static let cask = adaptive(light: 0x0EA5E9, dark: 0x38BDF8)
    static let updates = adaptive(light: 0x16A394, dark: 0x2DD4BF)
    static let node = adaptive(light: 0x3D9440, dark: 0x6ABF4B)
    static let npm = adaptive(light: 0xCB3837, dark: 0xF87171)
    static let globalPackages = adaptive(light: 0x2563EB, dark: 0x60A5FA)
    static let nvm = adaptive(light: 0xCA9A04, dark: 0xF4DD4B)
    static let commandLineTools = adaptive(light: 0x475569, dark: 0x94A3B8)
    static let zsh = adaptive(light: 0xE8531E, dark: 0xFB8C5B)
    static let ohMyZsh = adaptive(light: 0x525866, dark: 0x9CA3AF)

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
            case .homebrew:
                if await dashboard.installHomebrewSilently(installation: installation) {
                    await model.refresh()
                    dashboard.refreshShellProfileState()
                }
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
        VStack(alignment: .leading, spacing: 10) {
            DashboardSectionHeader("Homebrew", systemImage: "mug.fill", tint: HomeMetricPalette.homebrew)
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
        VStack(alignment: .leading, spacing: 10) {
            DashboardSectionHeader("Node", systemImage: "shippingbox.fill", tint: HomeMetricPalette.node)
            nodeMetrics(model.node.map(NodeDashboardSummary.init))
            if model.nodeUpdateState == .failed { inlineWarning("Updates could not be checked. Local information is still available.") }
            if model.nodeRefreshFailed { inlineWarning("Local Node refresh failed. Previously read information is retained.") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var terminalEnvironmentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DashboardSectionHeader("Terminal Environment", systemImage: "terminal.fill", tint: HomeMetricPalette.commandLineTools)
            terminalEnvironmentMetrics
            terminalEnvironmentSetup
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metricGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 190), spacing: 12, alignment: .top)]
    }

    private func homebrewMetrics(_ summary: HomebrewDashboardSummary?) -> some View {
        LazyVGrid(columns: metricGridColumns, alignment: .leading, spacing: 12) {
            let homebrewUpdateDetail = homebrewUpdateDetail(summary)
            let hasHomebrewPackageUpdates = (summary?.updates?.totalCount ?? 0) > 0 && model.homebrewUpdateState == .available
            StatusMetric(
                title: String(localized: "Homebrew"),
                value: homebrewVersion(summary),
                valueTint: (installation == .notInstalled || installation == .commandLineToolsRequired) ? .secondary : nil,
                valueSystemImage: homebrewUpdateDetail != nil ? "arrow.up.circle.fill" : nil,
                valueSystemImageHelp: homebrewUpdateDetail != nil ? "Update Available" : nil,
                titleLink: dashboard.officialHomebrewURL,
                titleLinkLabel: "Homebrew Website",
                detail: homebrewUpdateDetail,
                detailTint: homebrewUpdateDetail != nil ? .orange : nil,
                systemImage: "mug.fill",
                brandAssetName: "HomebrewBrand",
                tint: HomeMetricPalette.homebrew
            )
            StatusMetric(
                title: String(localized: "Formula"),
                value: metricCount(summary?.formulaCount),
                systemImage: "shippingbox.fill",
                brandAssetName: "FormulaIcon",
                tint: HomeMetricPalette.formula
            )
            StatusMetric(
                title: String(localized: "Cask"),
                value: metricCount(summary?.caskCount),
                systemImage: "app.grid",
                brandAssetName: "CaskIcon",
                tint: HomeMetricPalette.cask
            )
            StatusMetric(
                title: String(localized: "Updates"),
                value: updateMetricValue(summary?.updates, state: model.homebrewUpdateState),
                valueSystemImage: hasHomebrewPackageUpdates ? "arrow.up.circle.fill" : nil,
                valueSystemImageHelp: hasHomebrewPackageUpdates ? "Update Available" : nil,
                systemImage: "arrow.up.circle.fill",
                brandAssetName: "UpdatesIcon",
                tint: HomeMetricPalette.updates
            )
        }
    }

    private var terminalEnvironmentMetrics: some View {
        LazyVGrid(columns: metricGridColumns, alignment: .leading, spacing: 12) {
            let cltInstalled: Bool = {
                if case .available(.installed) = dashboard.commandLineTools { return true }
                return false
            }()
            let cltNotInstalled: Bool = {
                if case .available(.notInstalled) = dashboard.commandLineTools { return true }
                return false
            }()
            let omzInstalled = model.shell?.ohMyZshInstalled == true
            let omzNotInstalled = model.shell?.ohMyZshInstalled == false
            StatusMetric(
                title: String(localized: "Command Line Tools"),
                value: commandLineToolsValue,
                valueTint: cltNotInstalled ? .secondary : nil,
                statusDotColor: cltInstalled ? .green : nil,
                titleLink: CatalogWebsites.commandLineTools,
                titleLinkLabel: "Apple Installation Guide",
                systemImage: "hammer.fill",
                brandAssetName: "CommandLineToolsIcon",
                tint: HomeMetricPalette.commandLineTools
            )
            StatusMetric(
                title: String(localized: "Zsh"),
                value: zshVersion.number,
                detail: zshVersion.architecture,
                systemImage: "terminal.fill",
                brandAssetName: "ZshBrand",
                tint: HomeMetricPalette.zsh
            )
            StatusMetric(
                title: String(localized: "Oh My Zsh"),
                value: ohMyZshValue,
                valueTint: omzNotInstalled ? .secondary : nil,
                statusDotColor: omzInstalled ? .green : nil,
                systemImage: "bolt.fill",
                brandAssetName: "OhMyZshBrand",
                tint: HomeMetricPalette.ohMyZsh
            )
        }
    }

    private func nodeMetrics(_ summary: NodeDashboardSummary?) -> some View {
        let nodeUpdateDetail = summary.flatMap { HomeVersion.updateDetail(current: $0.nodeVersion, online: dashboard.onlineVersion(for: .node)) }
        let npmUpdateDetail = summary.flatMap { HomeVersion.updateDetail(current: $0.npmVersion, online: dashboard.onlineVersion(for: .npm)) }
        let hasNodePackageUpdates = (summary?.updates?.totalCount ?? 0) > 0 && model.nodeUpdateState == .available
        let nvmDefault = nvmDefaultValue(summary)
        let showsNvmDefault = nvmAvailable && nvmDefault != "—"
        return LazyVGrid(columns: metricGridColumns, alignment: .leading, spacing: 12) {
            StatusMetric(
                title: String(localized: "Node"),
                value: summary.map { HomeVersion.normalized($0.nodeVersion) } ?? "—",
                valueSystemImage: nodeUpdateDetail != nil ? "arrow.up.circle.fill" : nil,
                valueSystemImageHelp: nodeUpdateDetail != nil ? "Update Available" : nil,
                detail: nodeUpdateDetail,
                detailTint: nodeUpdateDetail != nil ? .orange : nil,
                systemImage: "shippingbox.fill",
                brandAssetName: "NodeBrand",
                tint: HomeMetricPalette.node
            )
            StatusMetric(
                title: String(localized: "npm"),
                value: summary.map { HomeVersion.normalized($0.npmVersion) } ?? "—",
                valueSystemImage: npmUpdateDetail != nil ? "arrow.up.circle.fill" : nil,
                valueSystemImageHelp: npmUpdateDetail != nil ? "Update Available" : nil,
                detail: npmUpdateDetail,
                detailTint: npmUpdateDetail != nil ? .orange : nil,
                systemImage: "shippingbox.circle.fill",
                brandAssetName: "NPMBrand",
                tint: HomeMetricPalette.npm
            )
            StatusMetric(
                title: String(localized: "Global Packages"),
                value: metricCount(summary?.packageCount),
                systemImage: "square.stack.3d.up.fill",
                brandAssetName: "GlobalPackagesIcon",
                tint: HomeMetricPalette.globalPackages
            )
            StatusMetric(
                title: String(localized: "Updates"),
                value: updateMetricValue(summary?.updates, state: model.nodeUpdateState),
                valueSystemImage: hasNodePackageUpdates ? "arrow.up.circle.fill" : nil,
                valueSystemImageHelp: hasNodePackageUpdates ? "Update Available" : nil,
                systemImage: "arrow.up.circle.fill",
                brandAssetName: "UpdatesIcon",
                tint: HomeMetricPalette.updates
            )
            StatusMetric(
                title: String(localized: "nvm"),
                value: showsNvmDefault ? nvmDefault : nvmValue,
                valueTint: model.nvmInstalled == false ? .secondary : nil,
                statusDotColor: nvmAvailable ? .green : nil,
                titleLink: CatalogWebsites.nvm,
                titleLinkLabel: "nvm Installation Guide",
                detail: showsNvmDefault ? String(localized: "nvm Default") : nil,
                systemImage: "point.3.connected.trianglepath.dotted",
                brandAssetName: "NVMBrand",
                tint: HomeMetricPalette.nvm
            )
        }
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
            return (installation == .notInstalled || installation == .commandLineToolsRequired)
                ? String(localized: "Not Installed") : "—"
        }
        return HomeVersion.normalized(current)
    }

    private func homebrewUpdateDetail(_ summary: HomebrewDashboardSummary?) -> String? {
        guard let current = summary?.version ?? model.homebrew?.version else { return nil }
        return HomeVersion.updateDetail(current: current, online: dashboard.onlineVersion(for: .homebrew))
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
