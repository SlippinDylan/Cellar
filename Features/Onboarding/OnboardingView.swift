import AppKit
import Combine
import SwiftUI

private enum OnboardingSetupRequest: Equatable {
    case commandLineTools, homebrew, finishInstaller, recheck
}

private enum OnboardingItemStatus: Equatable {
    case checking
    case ready
    case missing
    case actionRequired
    case warning
}

private enum OnboardingIntroPhase: Equatable {
    case playing(UUID)
    case finished
}

@MainActor
private final class OnboardingCloseController: ObservableObject {
    var allowsClose = false
}

struct OnboardingView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openURL) private var openURL
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ObservedObject var model: AppModel
    @ObservedObject private var dashboard: HomeDashboardModel
    @ObservedObject var onboardingState: OnboardingState
    let isStandaloneWindow: Bool
    @StateObject private var fdaVerification = ProtectedFileAccessVerification()
    @StateObject private var fdaGuide = FullDiskAccessGuide()
    @StateObject private var closeController = OnboardingCloseController()

    @State private var step: OnboardingStep = .welcome
    @State private var introPhase: OnboardingIntroPhase = .playing(UUID())
    @State private var isWindowVisible = false
    @State private var needsResetOnAppear = false
    @State private var hasCompletedInitialProbe = false
    @State private var didConfigureTerminalBrew = false
    @State private var setupRequest: OnboardingSetupRequest?
    @State private var showsSkipConfirmation = false
    @State private var requestedOhMyZshInstall = false
    @State private var fdaOpenFailed = false
    @State private var fdaVerificationRequestID = UUID()
    @State private var reactivationRefreshID: UUID?

    init(model: AppModel, onboardingState: OnboardingState, isStandaloneWindow: Bool = true) {
        self.model = model
        dashboard = model.homeDashboard
        self.onboardingState = onboardingState
        self.isStandaloneWindow = isStandaloneWindow
    }

    var body: some View {
        ZStack {
            switch introPhase {
            case .playing(let cycleID):
                OnboardingIntroAnimationView {
                    withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.45)) {
                        introPhase = .finished
                    }
                }
                .id(cycleID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .finished:
                onboardingContent
                    .transition(.opacity)
            }
        }
        .frame(width: 460, height: 560)
        .background(OnboardingWindowConfigurator(
            restoresMainWindowOnTeardown: !isStandaloneWindow,
            shouldClose: handleWindowShouldClose
        ))
        .alert("Skip Setup?", isPresented: $showsSkipConfirmation) {
            Button("Skip and Open Cellar") {
                finishAndOpenMainWindow()
            }
            Button("Continue Setup", role: .cancel) {}
        } message: {
            Text("You can run the setup guide again anytime from Settings.")
        }
        .sheet(item: onboardingShellPlanBinding) { plan in
            ShellTaskConfirmation(
                plan: plan,
                cancel: {
                    requestedOhMyZshInstall = false
                    model.dismissShellPlan(confirmed: plan)
                },
                confirm: {
                    Task {
                        await model.executeShellPlan(confirmed: plan)
                        requestedOhMyZshInstall = false
                    }
                }
            )
        }
        .onAppear {
            isWindowVisible = true
            closeController.allowsClose = false
            if needsResetOnAppear {
                needsResetOnAppear = false
                step = .welcome
                introPhase = .playing(UUID())
                fdaVerificationRequestID = UUID()
            }
        }
        .task {
            guard !AppRuntime.isRunningTests else { return }
            if model.refreshedAt == nil && !model.isRefreshing {
                await model.refresh()
            }
            await dashboard.refreshPrerequisitesOnly(showLoading: !hasCompletedInitialProbe)
            dashboard.refreshShellProfileState()
            hasCompletedInitialProbe = true
        }
        .task(id: fdaVerificationRequestID) {
            guard !AppRuntime.isRunningTests else { return }
            await fdaVerification.refresh()
        }
        .task(id: reactivationRefreshID) {
            guard reactivationRefreshID != nil, isWindowVisible, !AppRuntime.isRunningTests else { return }
            await dashboard.refreshPrerequisitesOnly(showLoading: false)
            dashboard.refreshShellProfileState()
        }
        .task(id: setupRequest) {
            guard let request = setupRequest else { return }
            switch request {
            case .commandLineTools:
                await dashboard.requestCommandLineTools(installation: .commandLineToolsRequired)
            case .homebrew:
                if await dashboard.installHomebrewSilently(installation: homebrewInstallation) {
                    if dashboard.isHomebrewInShellProfile {
                        didConfigureTerminalBrew = true
                    }
                    await model.refresh()
                    await dashboard.refreshPrerequisitesOnly(showLoading: false)
                }
            case .finishInstaller:
                if await dashboard.finishInstallerHandoff() {
                    await model.refresh()
                    await dashboard.refreshPrerequisitesOnly(showLoading: false)
                    dashboard.refreshShellProfileState()
                }
            case .recheck:
                await model.refresh()
                await dashboard.refreshPrerequisitesOnly(showLoading: false)
                dashboard.refreshShellProfileState()
                await fdaVerification.refresh()
            }
            setupRequest = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard isWindowVisible, !AppRuntime.isRunningTests else { return }
            fdaGuide.close()
            fdaVerificationRequestID = UUID()
            if step == .coreTools || step == .environment {
                reactivationRefreshID = UUID()
            }
        }
        .onDisappear {
            isWindowVisible = false
            needsResetOnAppear = true
            fdaGuide.close()
            fdaVerification.invalidate()
            closeController.allowsClose = false
            setupRequest = nil
            reactivationRefreshID = nil
            showsSkipConfirmation = false
            requestedOhMyZshInstall = false
            fdaOpenFailed = false
        }
    }

    // MARK: - Main Content Layout

    private var onboardingContent: some View {
        VStack(spacing: 0) {
            if step == .welcome {
                VStack(spacing: 16) {
                    Spacer(minLength: 0)
                    stepHeader
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 36)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    stepHeader
                }
                .padding(.top, step == .complete ? 28 : 20)
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity)

                GeometryReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            Spacer(minLength: 12)
                            stepBody
                            Spacer(minLength: 12)
                        }
                        .padding(.horizontal, 28)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    }
                    .scrollIndicators(.automatic)
                }
            }

            footer
                .padding(.bottom, step == .complete ? 22 : 28)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var stepHeader: some View {
        if step == .welcome {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)
        } else if step == .complete {
            OnboardingCelebrationIconView()
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)
        }

        VStack(spacing: 8) {
            Text(stepTitle)
                .font(.system(size: step == .welcome ? 28 : 24, weight: .semibold))
                .multilineTextAlignment(.center)

            Text(stepSubtitle)
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case .welcome:
            EmptyView()
        case .coreTools:
            VStack(spacing: 12) {
                commandLineToolsRow
                homebrewRow
            }
        case .environment:
            VStack(spacing: 12) {
                nodeRow
                ohMyZshRow
                fullDiskAccessRow
            }
        case .complete:
            completeSummaryCard
        }
    }

    // MARK: - Step 2: Core Tools

    private var commandLineToolsRow: some View {
        let status: OnboardingItemStatus = {
            if isCheckingCLT || dashboard.setupState == .requestingCommandLineTools { return .checking }
            if isCLTInstalled { return .ready }
            if case .failed(.commandLineTools) = dashboard.setupState { return .warning }
            if dashboard.commandLineTools == .failed { return .warning }
            return .missing
        }()

        return OnboardingSetupRow(
            icon: AnyView(Image("CommandLineToolsIcon").resizable().scaledToFit()),
            title: "Command Line Tools",
            subtitle: cltSubtitle,
            status: status
        ) {
            if isCLTInstalled {
                EmptyView()
            } else if dashboard.setupState == .commandLineToolsRequested {
                Button("Recheck") { setupRequest = .recheck }
                    .disabled(model.isBusy)
            } else if dashboard.commandLineTools == .available(.notInstalled) {
                Button("Install…") { setupRequest = .commandLineTools }
                    .disabled(model.isBusy || dashboard.setupState == .requestingCommandLineTools)
            } else if dashboard.commandLineTools == .failed {
                Button("Recheck") { setupRequest = .recheck }
                    .disabled(model.isBusy)
            }
        }
    }

    private var homebrewRow: some View {
        let isInstalling = dashboard.setupState == .preparingInstaller
        let status: OnboardingItemStatus = {
            if isProbing || isInstalling { return .checking }
            if isHomebrewInstalled { return .ready }
            if case .failed(.homebrew) = dashboard.setupState { return .warning }
            if case .unavailable = homebrewInstallation { return .warning }
            return .missing
        }()

        return OnboardingSetupRow(
            icon: AnyView(Image("HomebrewBrand").resizable().scaledToFit()),
            title: "Homebrew",
            subtitle: homebrewSubtitle,
            status: status,
            showsProgressBar: isInstalling
        ) {
            if isHomebrewInstalled {
                EmptyView()
            } else if dashboard.installerHandoffPending {
                Button("Recheck") { setupRequest = .finishInstaller }
                    .disabled(model.isBusy)
            } else if homebrewInstallation == .notInstalled {
                HStack(spacing: 8) {
                    if case .failed(.homebrew) = dashboard.setupState {
                        Button("Website") { openURL(CatalogWebsites.homebrew) }
                    }
                    Button("Install…") { setupRequest = .homebrew }
                        .disabled(model.isBusy || isInstalling)
                }
            } else if case .unavailable = homebrewInstallation {
                Button("Website") { openURL(CatalogWebsites.homebrew) }
            } else if homebrewInstallation == .commandLineToolsRequired {
                Button("Install…") {}
                    .disabled(true)
            }
        }
    }

    // MARK: - Step 3: Optional Stack & Permissions

    private var nodeRow: some View {
        let status: OnboardingItemStatus = {
            if isProbing { return .checking }
            if isNodeReady { return .ready }
            return .missing
        }()

        return OnboardingSetupRow(
            icon: AnyView(Image("NodeBrand").resizable().scaledToFit()),
            title: "Node.js & nvm",
            subtitle: nodeSubtitle,
            status: status
        ) {
            if isNodeReady {
                EmptyView()
            } else if model.nvmInstalled == true {
                Button("Recheck") { setupRequest = .recheck }
                    .disabled(model.isBusy)
            } else {
                HStack(spacing: 8) {
                    Button("Guide") { openURL(CatalogWebsites.nvm) }
                    Button("Recheck") { setupRequest = .recheck }
                        .disabled(model.isBusy)
                }
            }
        }
    }

    private var ohMyZshRow: some View {
        let status: OnboardingItemStatus = {
            if isProbing || model.isShellWorking { return .checking }
            if isOhMyZshInstalled { return .ready }
            if model.shellOperationError != nil { return .warning }
            return .missing
        }()

        return OnboardingSetupRow(
            icon: AnyView(Image("OhMyZshBrand").resizable().scaledToFit()),
            title: "Oh My Zsh",
            subtitle: ohMyZshSubtitle,
            status: status
        ) {
            if isOhMyZshInstalled {
                EmptyView()
            } else {
                Button("Install…") {
                    requestedOhMyZshInstall = true
                    Task {
                        await model.prepareShellAction(.init(action: .installOhMyZsh))
                        if model.shellPlan == nil { requestedOhMyZshInstall = false }
                    }
                }
                .disabled(model.isBusy || model.managers == nil)
            }
        }
    }

    private var fullDiskAccessRow: some View {
        let status: OnboardingItemStatus = {
            if fdaVerification.result == nil { return .checking }
            if fdaVerification.isVerified { return .ready }
            if fdaOpenFailed { return .warning }
            return .actionRequired
        }()

        return OnboardingSetupRow(
            icon: AnyView(
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
            ),
            title: "Full Disk Access",
            subtitle: fdaSubtitle,
            status: status
        ) {
            if fdaVerification.isVerified {
                EmptyView()
            } else {
                Button("Authorize…") {
                    fdaOpenFailed = !fdaGuide.open(locale: locale) {
                        fdaVerificationRequestID = UUID()
                    }
                }
            }
        }
    }

    // MARK: - Step 4: Complete Summary

    private var completeSummaryCard: some View {
        VStack(spacing: 10) {
            summaryRow(title: "Command Line Tools", ready: isCLTInstalled, checking: false)
            summaryRow(title: "Homebrew", ready: isHomebrewInstalled, checking: false)
            summaryRow(title: "Node.js & nvm", ready: isNodeReady, checking: false)
            summaryRow(title: "Oh My Zsh", ready: isOhMyZshInstalled, checking: false)
            summaryRow(title: "Full Disk Access", ready: fdaVerification.isVerified, checking: false)
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, 2)
    }

    private func summaryRow(title: LocalizedStringResource, ready: Bool, checking: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: checking ? "circle.dotted" : (ready ? "checkmark.circle.fill" : "circle"))
                .foregroundStyle(checking ? Color.secondary : (ready ? Color.green : Color.secondary.opacity(0.6)))
                .font(.system(size: 15))
                .contentTransition(.symbolEffect(.replace))
            Text(title)
                .font(.system(size: 13.5))
            Spacer(minLength: 0)
            Text(checking
                 ? LocalizedStringResource("Checking…")
                 : (ready ? LocalizedStringResource("Ready") : LocalizedStringResource("Not Set Up")))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(ready ? Color.green : Color.secondary)
        }
        .animation(reduceMotion ? nil : .smooth, value: ready)
        .animation(reduceMotion ? nil : .smooth, value: checking)
    }

    // MARK: - Footer Navigation (Buckle-inspired circular controls)

    private var footer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 16) {
                if let previous = step.previous, step != .complete {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            step = previous
                        }
                    } label: {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, height: 40)
                            .background(Color(nsColor: .controlBackgroundColor), in: Circle())
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                    .help("Back")
                }

                Button {
                    advance()
                } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .frame(width: 52, height: 52)
                        .background(Color.primary, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(primaryActionTitle)
                .help(primaryActionTitle)
            }

            if step == .complete {
                Text("Start Using Cellar")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Derived State & Copy

    private var homebrewInstallation: HomebrewInstallationState {
        dashboard.installationState(
            homebrew: model.homebrew,
            readFailed: model.homebrewRefreshFailed,
            hasRefreshed: model.refreshedAt != nil
        )
    }

    private var isProbing: Bool {
        !hasCompletedInitialProbe && model.refreshedAt == nil && !AppRuntime.isRunningTests
    }

    private var isCheckingCLT: Bool {
        !hasCompletedInitialProbe && (dashboard.commandLineTools == .notLoaded || dashboard.commandLineTools == .loading)
    }

    private var isCLTInstalled: Bool {
        if case .available(.installed) = dashboard.commandLineTools { return true }
        return false
    }

    private var isHomebrewInstalled: Bool {
        if case .installed = homebrewInstallation { return true }
        return false
    }

    private var isNodeReady: Bool {
        model.node != nil
    }

    private var isOhMyZshInstalled: Bool {
        model.shell?.ohMyZshInstalled == true
    }

    private var stepTitle: LocalizedStringResource {
        switch step {
        case .welcome: "Welcome to Cellar"
        case .coreTools: "Core Tools"
        case .environment: "Environment & Permissions"
        case .complete: "You’re All Set"
        }
    }

    private var stepSubtitle: LocalizedStringResource {
        switch step {
        case .welcome: "Cellar checks your Mac’s developer tools and helps you configure what you need before opening your workspace."
        case .coreTools: "Command Line Tools and Homebrew power package management in Cellar. You can skip anything you don’t need."
        case .environment: "Set up optional developer tools and grant Full Disk Access for thorough Cask uninstallation."
        case .complete: "Your workspace is ready. You can adjust any tool or permission anytime in Environment or Settings."
        }
    }

    private var primaryActionTitle: LocalizedStringResource {
        switch step {
        case .welcome: "Get Started"
        case .coreTools, .environment: "Next"
        case .complete: "Start Using Cellar"
        }
    }

    private var cltSubtitle: Text {
        if isCheckingCLT { return Text("Checking…") }
        if isCLTInstalled { return Text("Installed") }
        if dashboard.setupState == .requestingCommandLineTools { return Text("Preparing System Installation") }
        if dashboard.setupState == .commandLineToolsRequested { return Text("Finish in the system dialog, then recheck.") }
        if case .failed(.commandLineTools) = dashboard.setupState { return Text(HomeSetupFailure.commandLineTools.message) }
        if dashboard.commandLineTools == .failed { return Text("Command Line Tools could not be checked.") }
        return Text("Required before installing Homebrew. macOS handles the installation.")
    }

    private var homebrewSubtitle: Text {
        if isProbing { return Text("Checking…") }
        if case .installed(let info) = homebrewInstallation {
            if didConfigureTerminalBrew {
                return Text("Installed (\(info.version)) · Ready in new Terminal windows.")
            }
            return Text("Installed (\(info.version))")
        }
        if dashboard.setupState == .preparingInstaller {
            switch dashboard.homebrewInstallProgress {
            case .fetchingRelease: return Text("Fetching official Homebrew release…")
            case .downloading: return Text("Downloading official Homebrew installer…")
            case .verifying: return Text("Verifying official package…")
            case .installing: return Text("Installing Homebrew…")
            case nil: return Text("Preparing System Installation")
            }
        }
        if dashboard.installerHandoffPending { return Text("Complete installation in macOS Installer, then recheck.") }
        if case .failed(.homebrew(let failure)) = dashboard.setupState { return Text(HomeSetupFailure.homebrew(failure).message) }
        if homebrewInstallation == .commandLineToolsRequired { return Text("Install Command Line Tools first.") }
        if case .unavailable = homebrewInstallation { return Text("Homebrew is unavailable. Check the official website for guidance.") }
        return Text("Not Installed")
    }

    private var nodeSubtitle: Text {
        if isProbing { return Text("Checking…") }
        if let node = model.node {
            return Text("Node \(HomeVersion.normalized(node.summary.nodeVersion))")
        }
        if model.nvmInstalled == true {
            return Text("nvm is installed. Add a Node version in Environment after setup.")
        }
        return Text("Optional. Install nvm using the official guide to manage Node versions.")
    }

    private var ohMyZshSubtitle: Text {
        if isProbing { return Text("Checking…") }
        if model.isShellWorking { return Text("Installing Oh My Zsh…") }
        if isOhMyZshInstalled { return Text("Installed") }
        if let error = model.shellOperationError { return Text(verbatim: error) }
        return Text("Optional. Manage Zsh themes and plugins from Cellar.")
    }

    private var fdaSubtitle: Text {
        if fdaVerification.result == nil { return Text("Checking…") }
        if fdaVerification.isVerified { return Text("Access Verified") }
        if fdaOpenFailed { return Text("Open System Settings > Privacy & Security > Full Disk Access.") }
        return Text("Inspect protected application data during uninstallation.")
    }

    private var onboardingShellPlanBinding: Binding<ShellActionPlan?> {
        Binding(
            get: {
                guard requestedOhMyZshInstall, let plan = model.shellPlan, plan.request.action == .installOhMyZsh else {
                    return nil
                }
                return plan
            },
            set: { newValue in
                if newValue == nil {
                    requestedOhMyZshInstall = false
                    if let plan = model.shellPlan, plan.request.action == .installOhMyZsh {
                        model.dismissShellPlan(confirmed: plan)
                    }
                }
            }
        )
    }

    // MARK: - Actions

    private func advance() {
        if let next = step.next {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                step = next
            }
        } else {
            finishAndOpenMainWindow()
        }
    }

    private func handleWindowShouldClose() -> Bool {
        if closeController.allowsClose || onboardingState.isCompleted { return true }
        if step == .complete {
            finishAndOpenMainWindow()
            return isStandaloneWindow
        }
        showsSkipConfirmation = true
        return false
    }

    private func finishAndOpenMainWindow() {
        fdaGuide.close()
        onboardingState.markCompleted()
        if isStandaloneWindow {
            closeController.allowsClose = true
            openWindow(id: AppScene.mainWindowID, value: MainWindowIdentity.main)
            withTransaction(\.dismissBehavior, .destructive) {
                dismissWindow(id: AppScene.onboardingWindowID)
            }
        }
    }
}

// MARK: - Reusable Row & Morphing Status Glyph

private struct OnboardingSetupRow<Action: View>: View {
    let icon: AnyView
    let title: LocalizedStringResource
    let subtitle: Text
    let status: OnboardingItemStatus
    var showsProgressBar: Bool = false
    @ViewBuilder let action: () -> Action

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                icon
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                        OnboardingStatusGlyph(status: status)
                    }
                    subtitle
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                action()
                    .controlSize(.large)
            }

            if showsProgressBar {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct OnboardingStatusGlyph: View {
    let status: OnboardingItemStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    @ViewBuilder
    var body: some View {
        if let symbolName {
            Image(systemName: symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(symbolColor)
                .contentTransition(.symbolEffect(.replace))
                .scaleEffect(breathing && !reduceMotion ? 1.14 : 1.0)
                .animation(reduceMotion ? nil : .smooth, value: status)
                .animation(
                    breathing && !reduceMotion
                        ? .easeInOut(duration: 0.75).repeatForever(autoreverses: true)
                        : .easeOut(duration: 0.2),
                    value: breathing
                )
                .onAppear { breathing = status == .checking }
                .onChange(of: status) { _, newValue in breathing = newValue == .checking }
                .accessibilityHidden(true)
        }
    }

    private var symbolName: String? {
        switch status {
        case .checking: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill"
        case .ready: "checkmark.circle.fill"
        case .missing: nil
        case .actionRequired: "exclamationmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private var symbolColor: Color {
        switch status {
        case .checking: .accentColor
        case .ready: .green
        case .missing: .secondary
        case .actionRequired: .orange
        case .warning: .orange
        }
    }
}
