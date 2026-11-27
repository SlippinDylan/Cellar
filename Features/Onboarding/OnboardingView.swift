import AppKit
import Combine
import SwiftUI

private enum OnboardingSetupRequest: Equatable {
    case commandLineTools, homebrew, node, finishInstaller
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
    @ObservedObject private var operationStore: OperationStore
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

    @State private var isWaitingForCLT = false
    @State private var cltStartedAt: Date?
    @State private var cltNeedsReinstall = false

    @State private var homebrewNeedsReinstall = false
    @State private var isRefreshingHomebrewAfterInstall = false
    @State private var didConfigureTerminalBrew = false

    @State private var isInstallingNode = false
    @State private var nodeNeedsReinstall = false
    @State private var nodeInstallError: String?

    @State private var requestedOhMyZshInstall = false
    @State private var omzNeedsReinstall = false
    @State private var retainedShellPlan: ShellActionPlan?

    @State private var setupRequest: OnboardingSetupRequest?
    @State private var showsSkipConfirmation = false
    @State private var showsBusyExitAlert = false
    @State private var fdaOpenFailed = false
    @State private var fdaVerificationRequestID = UUID()
    @State private var reactivationRefreshID: UUID?

    init(model: AppModel, onboardingState: OnboardingState, isStandaloneWindow: Bool = true) {
        self.model = model
        operationStore = model.operationStore
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
            Text("You can configure developer tools anytime in Home, Environment, or Settings.")
        }
        .alert("Operation in Progress", isPresented: $showsBusyExitAlert) {
            Button("Got It", role: .cancel) {
                model.operationStore.dismissTerminationBlockedNotice()
            }
        } message: {
            Text("Wait for the current installation or environment check to finish before quitting Cellar.")
        }
        .onChange(of: operationStore.terminationBlockedNotice) { _, blocked in
            if blocked && isWindowVisible {
                showsBusyExitAlert = true
            }
        }
        .sheet(item: onboardingShellPlanBinding) { plan in
            ShellTaskConfirmation(
                plan: plan,
                cancel: {
                    retainedShellPlan = nil
                    requestedOhMyZshInstall = false
                    model.dismissShellPlan(confirmed: plan)
                    model.dismissShellFeedback()
                },
                confirm: {
                    retainedShellPlan = plan
                    model.dismissShellFeedback()
                    await model.executeShellPlan(confirmed: plan)
                    if model.shell?.ohMyZshInstalled != true {
                        omzNeedsReinstall = true
                    }
                    if let error = model.shellOperationError { return error }
                    guard let result = model.shellActionResult, result.plan.id == plan.id else {
                        return String(localized: ActivityItemReason.stateUnavailable.message)
                    }
                    return result.operation.exitCode == 0 ? nil : String(localized: ActivityItemReason.providerFailure.message)
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
            if isWaitingForCLT {
                evaluateCLTWaitedState(onReactivation: true)
            }
        }
        // Poll Command Line Tools while the macOS system installation dialog is active.
        .task(id: isWaitingForCLT) {
            guard isWaitingForCLT, !AppRuntime.isRunningTests else { return }
            while !Task.isCancelled && isWaitingForCLT {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled && isWaitingForCLT else { return }
                await dashboard.refreshPrerequisitesOnly(showLoading: false)
                evaluateCLTWaitedState(onReactivation: false)
            }
        }
        .task(id: setupRequest) {
            guard let request = setupRequest else { return }
            switch request {
            case .commandLineTools:
                cltNeedsReinstall = false
                isWaitingForCLT = true
                cltStartedAt = Date()
                await dashboard.requestCommandLineTools(installation: .commandLineToolsRequired)
                if case .failed(.commandLineTools) = dashboard.setupState {
                    isWaitingForCLT = false
                    cltNeedsReinstall = true
                }
            case .homebrew:
                homebrewNeedsReinstall = false
                let installed = await dashboard.installHomebrewSilently(installation: homebrewInstallation)
                if installed {
                    isRefreshingHomebrewAfterInstall = true
                    defer { isRefreshingHomebrewAfterInstall = false }
                    if dashboard.isHomebrewInShellProfile {
                        didConfigureTerminalBrew = true
                    }
                    await model.refresh()
                    await dashboard.refreshPrerequisitesOnly(showLoading: false)
                } else {
                    homebrewNeedsReinstall = true
                }
            case .node:
                nodeNeedsReinstall = false
                nodeInstallError = nil
                isInstallingNode = true
                defer { isInstallingNode = false }
                let installed = await model.installNodeWithHomebrew()
                if !installed {
                    nodeNeedsReinstall = true
                    nodeInstallError = model.homebrewOperationError
                    model.dismissHomebrewFeedback()
                }
            case .finishInstaller:
                if await dashboard.finishInstallerHandoff() {
                    await model.refresh()
                    await dashboard.refreshPrerequisitesOnly(showLoading: false)
                }
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
            isWaitingForCLT = false
            cltStartedAt = nil
            cltNeedsReinstall = false
            homebrewNeedsReinstall = false
            isRefreshingHomebrewAfterInstall = false
            didConfigureTerminalBrew = false
            isInstallingNode = false
            nodeNeedsReinstall = false
            nodeInstallError = nil
            omzNeedsReinstall = false
            fdaGuide.close()
            fdaVerification.invalidate()
            closeController.allowsClose = false
            setupRequest = nil
            reactivationRefreshID = nil
            showsSkipConfirmation = false
            showsBusyExitAlert = false
            requestedOhMyZshInstall = false
            retainedShellPlan = nil
            fdaOpenFailed = false
            model.dismissHomebrewFeedback()
            model.dismissShellFeedback()
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
        let isBusyInstalling = isWaitingForCLT || dashboard.setupState == .requestingCommandLineTools

        return OnboardingSetupRow(
            icon: AnyView(Image("CommandLineToolsIcon").resizable().scaledToFit()),
            title: "Command Line Tools",
            subtitle: cltSubtitle,
            showsProgressBar: false
        ) {
            if isCLTInstalled {
                installedCheckmark
            } else if isBusyInstalling || isCheckingCLT {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(cltNeedsReinstall ? LocalizedStringResource("Reinstall") : LocalizedStringResource("Install Now")) {
                    setupRequest = .commandLineTools
                }
                .disabled(model.isBusy)
            }
        }
    }

    private var homebrewRow: some View {
        let isInstalling = dashboard.setupState == .preparingInstaller

        return OnboardingSetupRow(
            icon: AnyView(Image("HomebrewBrand").resizable().scaledToFit()),
            title: "Homebrew",
            subtitle: homebrewSubtitle,
            showsProgressBar: isInstalling
        ) {
            if isHomebrewInstalled {
                installedCheckmark
            } else if isInstalling || isCheckingHomebrew {
                ProgressView()
                    .controlSize(.small)
            } else if homebrewInstallation == .notInstalled {
                HStack(spacing: 8) {
                    if case .failed(.homebrew) = dashboard.setupState {
                        Button("Website") { openURL(CatalogWebsites.homebrew) }
                    }
                    Button(homebrewNeedsReinstall ? LocalizedStringResource("Reinstall") : LocalizedStringResource("Install Now")) {
                        setupRequest = .homebrew
                    }
                    .disabled(model.isBusy)
                }
            } else if case .unavailable = homebrewInstallation {
                Button("Website") { openURL(CatalogWebsites.homebrew) }
            } else {
                Button("Install Now") {}
                    .disabled(true)
            }
        }
    }

    // MARK: - Step 3: Optional Stack & Permissions

    private var nodeRow: some View {
        OnboardingSetupRow(
            icon: AnyView(Image("NodeBrand").resizable().scaledToFit()),
            title: "Node.js",
            subtitle: nodeSubtitle,
            showsProgressBar: isInstallingNode
        ) {
            if isNodeReady {
                installedCheckmark
            } else if isInstallingNode || isProbing {
                ProgressView()
                    .controlSize(.small)
            } else if isHomebrewInstalled {
                Button(nodeNeedsReinstall ? LocalizedStringResource("Reinstall") : LocalizedStringResource("Install Now")) {
                    setupRequest = .node
                }
                .disabled(model.isBusy)
            } else {
                Button("Install Now") {}
                    .disabled(true)
            }
        }
    }

    private var ohMyZshRow: some View {
        let isInstalling = model.isShellWorking

        return OnboardingSetupRow(
            icon: AnyView(Image("OhMyZshBrand").resizable().scaledToFit()),
            title: "Oh My Zsh",
            subtitle: ohMyZshSubtitle,
            showsProgressBar: isInstalling
        ) {
            if isOhMyZshInstalled {
                installedCheckmark
            } else if isInstalling || isProbing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(omzNeedsReinstall ? LocalizedStringResource("Reinstall") : LocalizedStringResource("Install Now")) {
                    omzNeedsReinstall = false
                    requestedOhMyZshInstall = true
                    Task {
                        await model.prepareShellAction(.init(action: .installOhMyZsh))
                        if model.shellPlan == nil {
                            requestedOhMyZshInstall = false
                            omzNeedsReinstall = true
                        }
                    }
                }
                .disabled(model.isBusy || model.managers == nil)
            }
        }
    }

    private var fullDiskAccessRow: some View {
        OnboardingSetupRow(
            icon: AnyView(
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
            ),
            title: "Full Disk Access",
            subtitle: fdaSubtitle,
            showsProgressBar: false
        ) {
            if fdaVerification.isVerified {
                installedCheckmark
            } else if fdaVerification.result == nil {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Authorize…") {
                    fdaOpenFailed = !fdaGuide.open(locale: locale) {
                        fdaVerificationRequestID = UUID()
                    }
                }
            }
        }
    }

    private var installedCheckmark: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 22))
            .foregroundStyle(Color.green)
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel("Installed")
    }

    // MARK: - Step 4: Complete Summary

    private var completeSummaryCard: some View {
        VStack(spacing: 10) {
            summaryRow(title: "Command Line Tools", ready: isCLTInstalled)
            summaryRow(title: "Homebrew", ready: isHomebrewInstalled)
            summaryRow(title: "Node.js", ready: isNodeReady)
            summaryRow(title: "Oh My Zsh", ready: isOhMyZshInstalled)
            summaryRow(title: "Full Disk Access", ready: fdaVerification.isVerified)
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, 2)
    }

    private func summaryRow(title: LocalizedStringResource, ready: Bool) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13.5))
            Spacer(minLength: 0)
            if ready {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                    .font(.system(size: 16))
                    .accessibilityLabel("Ready")
            } else {
                Text("Not Set Up")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
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
                    .disabled(isOnboardingBusy)
                    .opacity(isOnboardingBusy ? 0.35 : 1)
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
                .disabled(isOnboardingBusy)
                .opacity(isOnboardingBusy ? 0.35 : 1)
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

    private var isCheckingHomebrew: Bool {
        isProbing || isRefreshingHomebrewAfterInstall || (model.isRefreshing && !isHomebrewInstalled)
    }

    private var isOnboardingBusy: Bool {
        isProbing
            || isCheckingCLT
            || isCheckingHomebrew
            || isWaitingForCLT
            || dashboard.setupState == .requestingCommandLineTools
            || dashboard.setupState == .preparingInstaller
            || isInstallingNode
            || model.isShellWorking
            || model.isRefreshing
            || model.operationStore.hasActiveOperations
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
        if isWaitingForCLT || dashboard.setupState == .requestingCommandLineTools {
            return Text("Waiting for macOS Command Line Tools installation…")
        }
        if case .failed(.commandLineTools) = dashboard.setupState { return Text(HomeSetupFailure.commandLineTools.message) }
        if dashboard.commandLineTools == .failed { return Text("Command Line Tools could not be checked.") }
        return Text("Required before installing Homebrew. macOS handles the installation.")
    }

    private var homebrewSubtitle: Text {
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
        if isCheckingHomebrew { return Text("Checking…") }
        if case .failed(.homebrew(let failure)) = dashboard.setupState { return Text(HomeSetupFailure.homebrew(failure).message) }
        if homebrewInstallation == .commandLineToolsRequired { return Text("Install Command Line Tools first.") }
        if case .unavailable = homebrewInstallation { return Text("Homebrew is unavailable. Check the official website for guidance.") }
        return Text("Not Installed")
    }

    private var nodeSubtitle: Text {
        if isProbing { return Text("Checking…") }
        if isInstallingNode { return Text("Installing Node.js with Homebrew…") }
        if let node = model.node {
            return Text("Node \(HomeVersion.normalized(node.summary.nodeVersion))")
        }
        if let nodeInstallError { return Text(verbatim: nodeInstallError) }
        if !isHomebrewInstalled {
            return Text("Install Homebrew first to install Node.js automatically.")
        }
        return Text("Not Installed")
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
                if let retainedShellPlan { return retainedShellPlan }
                guard requestedOhMyZshInstall, let plan = model.shellPlan, plan.request.action == .installOhMyZsh else {
                    return nil
                }
                return plan
            },
            set: { newValue in
                if newValue == nil {
                    retainedShellPlan = nil
                    requestedOhMyZshInstall = false
                    if let plan = model.shellPlan, plan.request.action == .installOhMyZsh {
                        model.dismissShellPlan(confirmed: plan)
                    }
                    model.dismissShellFeedback()
                }
            }
        )
    }

    // MARK: - Actions

    private func evaluateCLTWaitedState(onReactivation: Bool) {
        if isCLTInstalled {
            isWaitingForCLT = false
            cltNeedsReinstall = false
            return
        }
        let elapsed = cltStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        guard elapsed >= 4 else { return }
        if !Self.isSystemCLTInstallerRunning() && (onReactivation || elapsed >= 6) {
            isWaitingForCLT = false
            cltNeedsReinstall = true
        }
    }

    private static func isSystemCLTInstallerRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            if app.bundleIdentifier == "com.apple.dt.CommandLineTools.installondemand" { return true }
            if let name = app.localizedName, name.localizedCaseInsensitiveContains("Command Line Developer Tools") { return true }
            return false
        }
    }

    private func advance() {
        guard !isOnboardingBusy else { return }
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
        if isOnboardingBusy {
            showsBusyExitAlert = true
            return false
        }
        if step == .complete {
            finishAndOpenMainWindow()
            return isStandaloneWindow
        }
        showsSkipConfirmation = true
        return false
    }

    private func finishAndOpenMainWindow() {
        isWaitingForCLT = false
        fdaGuide.close()
        // Clear any setup banners generated during onboarding so the main window opens clean.
        model.activityStore?.dismissResult()
        model.dismissHomebrewFeedback()
        model.dismissShellFeedback()
        model.dismissNodeFeedback()
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

// MARK: - Unified Onboarding Setup Row

private struct OnboardingSetupRow<Trailing: View>: View {
    let icon: AnyView
    let title: LocalizedStringResource
    let subtitle: Text
    var showsProgressBar: Bool = false
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                icon
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    subtitle
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                trailing()
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
