import SwiftUI

struct RuntimeToolsView: View {
    @ObservedObject var model: AppModel
    @State private var installations: [NodeInstallation] = []
    @State private var showsInstallation = false
    @State private var nodeToUse: NodeInstallation?
    @State private var showsHomebrewNodeInstall = false
    @State private var installationsLoaded = false

    init(model: AppModel) {
        self.model = model
    }

    private var nvmAvailable: Bool? {
        model.nvmInstalled
    }

    private var nvmSectionFooter: LocalizedStringResource? {
        switch nvmAvailable {
        case true: nil
        case false: "nvm manages multiple Node versions. Install it using the official guide to add or switch versions here."
        case nil: "Check nvm availability before managing Node versions."
        }
    }

    var body: some View {
        SettingsPage(fillsViewport: true) {
            SettingsSection(title: "nvm", website: CatalogWebsites.nvm, websiteTitle: "nvm Installation Guide", footer: nvmSectionFooter) {
                if model.node == nil && model.homebrew?.isInstalled == true {
                    HStack(spacing: 12) {
                        Text("Install Node.js directly with Homebrew without setting up nvm.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Install Node with Homebrew") {
                            showsHomebrewNodeInstall = true
                        }
                        .disabled(model.isBusy)
                        .fixedSize()
                    }
                    .frame(minHeight: AppLayout.minimumControlRowHeight)
                    Divider()
                }
                HStack(alignment: .center, spacing: 12) {
                    switch nvmAvailable {
                    case true: Label("Installed", systemImage: "checkmark.circle")
                    case false: Text("Not Installed").foregroundStyle(.secondary)
                    case nil: Text("Not Checked").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Recheck") {
                        Task {
                            await model.refresh()
                        }
                    }
                        .disabled(model.isBusy)
                }
                .frame(minHeight: AppLayout.minimumControlRowHeight)
                if nvmAvailable == true {
                    defaultVersion
                    installedVersions
                }
            }
            Spacer(minLength: 0)
            EnvironmentFooterView {
                if let node = model.node {
                    LabeledContent("Node Version", value: node.summary.nodeVersion)
                    LabeledContent("npm Version", value: node.summary.npmVersion)
                } else {
                    Text("Node Environment Unavailable")
                }
            }
        }
        .task(id: model.refreshedAt) {
            guard !AppRuntime.isRunningTests else { return }
            installationsLoaded = false
            installations = await model.service.runtimeInstallations(preferredVersion: model.preferredNodeVersion)
            installationsLoaded = true
        }
        .sheet(isPresented: $showsInstallation) {
            NodeInstallationSheet(model: model, canInstall: nvmAvailable == true)
                .onAppear { model.beginModalPresentation() }
                .onDisappear {
                    model.dismissNodeFeedback()
                    model.endModalPresentation()
                }
        }
        .sheet(item: $nodeToUse) { installation in
            NodeDirectActionSheet(model: model, request: .init(action: .useNode, subject: installation.version))
                .onAppear { model.beginModalPresentation() }
                .onDisappear {
                    model.dismissNodeFeedback()
                    model.endModalPresentation()
                }
        }
        .sheet(isPresented: $showsHomebrewNodeInstall) {
            NodeHomebrewInstallSheet(model: model)
                .onAppear { model.beginModalPresentation() }
                .onDisappear {
                    model.dismissHomebrewFeedback()
                    model.endModalPresentation()
                }
        }
    }

    private var defaultVersion: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("nvm Default")
                    if !installationsLoaded {
                        Text("Not Checked").foregroundStyle(.secondary)
                    } else if let version = installations.first(where: \.isDefault)?.version {
                        Text(version).font(.body.monospaced()).foregroundStyle(.secondary)
                    } else {
                        Text("Unresolved").foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button("Use nvm Default") { Task { await model.restoreDefaultNodeSession() } }
                .disabled(!installations.contains(where: \.isDefault) || model.isBusy)
        }
        .frame(minHeight: AppLayout.minimumDescribedRowHeight)
    }

    private var installedVersions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.vertical, 12)
            HStack {
                Text("Versions Managed by nvm").fontWeight(.medium)
                Spacer()
                Button("Install Version", systemImage: "plus") { showsInstallation = true }
                    .disabled(model.isBusy)
            }.padding(.bottom, 8)
            if !installationsLoaded {
                ProgressView("Reading Installed Versions…")
            } else if installations.isEmpty {
                Text("No versions are installed through nvm. The Node version used by Cellar may come from another installation.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(installations) { item in
                HStack(spacing: 12) {
                    Text(item.version).font(.body.monospaced()).textSelection(.enabled)
                    if item.isActive { Label("Used by Cellar", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                    if item.isDefault { Label("Default", systemImage: "star").foregroundStyle(.secondary) }
                    Spacer()
                    Button("Use for Cellar") { nodeToUse = item }
                        .disabled(item.isActive || model.isBusy)
                    Menu {
                        Button("Set as Default…") { Task { await model.prepareNodeAction(.init(action: .setDefaultNode, subject: item.version)) } }
                            .disabled(item.isDefault || model.isBusy)
                        Button("Uninstall Node…", role: .destructive) { Task { await model.prepareNodeAction(.init(action: .uninstallNode, subject: item.version)) } }
                            .disabled(!RuntimeProtection.canUninstall(item) || model.isBusy)
                    } label: {
                        Label("Version Actions", systemImage: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .labelStyle(.iconOnly)
                    .fixedSize()
                    .disabled(model.isBusy)
                }.frame(minHeight: 44)
                    .disabled(!installationsLoaded)
                if item.id != installations.last?.id { Divider() }
            }
        }
    }
}

private struct NodeInstallationSheet: View {
    @ObservedObject var model: AppModel
    let canInstall: Bool
    @StateObject private var runtime = RuntimeToolsModel()
    @State private var selectedRelease = ""
    @State private var versionToInstall: String?
    @State private var didLoad = false
    @State private var retryTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let versionToInstall {
            NodeDirectActionSheet(model: model, request: .init(action: .installNode, subject: versionToInstall))
        } else {
            installationForm
        }
    }

    private var installationForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Install Node Version").font(.title2.bold())
            Text("Choose an official Node version to install with nvm.").foregroundStyle(.secondary)
            if !didLoad || runtime.isLoading {
                ProgressView("Loading Official Node Versions…")
            } else if let error = runtime.error {
                Label { Text(error.message) } icon: { Image(systemName: "exclamationmark.triangle") }
                Button("Retry") {
                    retryTask?.cancel()
                    retryTask = Task { await runtime.refresh(model: model) }
                }.disabled(model.isBusy)
            } else if runtime.releases.isEmpty {
                Text("No Node releases are available. Try again.")
                Button("Retry") {
                    retryTask?.cancel()
                    retryTask = Task { await runtime.refresh(model: model) }
                }.disabled(model.isBusy)
            } else {
                Picker("Node Version", selection: $selectedRelease) {
                    Text("Choose a Version").tag("")
                    ForEach(runtime.releases) { release in Text(release.version).tag(release.version) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Install Node") { versionToInstall = selectedRelease }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedRelease.isEmpty || runtime.isLoading || model.isBusy || !canInstall)
            }
        }
        .padding(24)
        .frame(width: 440)
        .task {
            guard !AppRuntime.isRunningTests else { return }
            await runtime.refresh(model: model)
            didLoad = true
        }
        .onDisappear {
            retryTask?.cancel()
            retryTask = nil
        }
    }
}

private struct NodeDirectActionSheet: View {
    @ObservedObject var model: AppModel
    let request: NodeActionRequest
    @Environment(\.dismiss) private var dismiss
    @State private var isRunning = true
    @State private var hasStarted = false
    @State private var errorMessage: String?

    var body: some View {
        MaintenanceModalFrame(
            title: request.action == .installNode ? LocalizedStringResource("Install Node Version") : LocalizedStringResource("Use for Cellar"),
            systemImage: "shippingbox.fill",
            tint: .green,
            width: 420,
            showsFooter: !isRunning
        ) {
            Text(verbatim: request.subject).foregroundStyle(.secondary)
        } content: {
            if isRunning {
                MaintenanceLoadingState(title: LocalizedStringResource("Running"))
            } else {
                HStack(alignment: errorMessage == nil ? .center : .top, spacing: 10) {
                    Image(systemName: errorMessage == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(errorMessage == nil ? .green : .orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(errorMessage == nil ? LocalizedStringResource("All actions finished successfully.") : LocalizedStringResource("Operation Failed"))
                            .font(.body.weight(.medium))
                        if let errorMessage {
                            Text(verbatim: errorMessage)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }
        } footer: {
            Spacer()
            if !isRunning {
                Button("OK") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .interactiveDismissDisabled(isRunning)
        .task {
            guard !hasStarted else { return }
            hasStarted = true
            await model.performDirectNodeAction(request)
            errorMessage = model.nodeOperationError
            if errorMessage == nil, model.nodeActionResult?.operation.batchItemStatus != .succeeded {
                errorMessage = String(localized: ActivityItemReason.stateUnavailable.message)
            }
            isRunning = false
        }
    }
}

private struct NodeHomebrewInstallSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var isRunning = true
    @State private var hasStarted = false
    @State private var succeeded = false
    @State private var installedVersion: String?
    @State private var errorMessage: String?

    var body: some View {
        MaintenanceModalFrame(
            title: LocalizedStringResource("Install Node with Homebrew"),
            systemImage: "shippingbox.fill",
            tint: .green,
            width: 420,
            showsFooter: !isRunning
        ) {
            if isRunning {
                Text("Running").foregroundStyle(.secondary)
            } else {
                Text(succeeded ? LocalizedStringResource("Completed") : LocalizedStringResource("Operation Failed"))
                    .foregroundStyle(succeeded ? .green : .orange)
            }
        } content: {
            if isRunning {
                MaintenanceLoadingState(title: LocalizedStringResource("Installing Node.js with Homebrew…"))
            } else {
                HStack(alignment: succeeded ? .center : .top, spacing: 10) {
                    Image(systemName: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(succeeded ? .green : .orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(succeeded ? LocalizedStringResource("All actions finished successfully.") : LocalizedStringResource("Operation Failed"))
                            .font(.body.weight(.medium))
                        if succeeded, let installedVersion {
                            Text("Node \(installedVersion)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else if let errorMessage {
                            Text(verbatim: errorMessage)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }
        } footer: {
            Spacer()
            if !isRunning {
                Button("OK") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .interactiveDismissDisabled(isRunning)
        .task {
            guard !hasStarted else { return }
            hasStarted = true
            isRunning = true
            defer { isRunning = false }
            let installed = await model.installNodeWithHomebrew()
            succeeded = installed
            if installed {
                installedVersion = model.node.map { HomeVersion.normalized($0.summary.nodeVersion) }
            } else {
                errorMessage = model.homebrewOperationError
            }
        }
    }
}
