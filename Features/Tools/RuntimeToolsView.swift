import SwiftUI

struct RuntimeToolsView: View {
    @ObservedObject var model: AppModel
    @State private var installations: [NodeInstallation] = []
    @State private var showsInstallation = false
    @State private var installationsLoaded = false

    init(model: AppModel) {
        self.model = model
    }

    private var nvmAvailable: Bool? {
        model.nvmInstalled
    }

    var body: some View {
        SettingsPage(fillsViewport: true) {
            SettingsSection(title: "nvm", website: CatalogWebsites.nvm, websiteTitle: "nvm Installation Guide") {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        switch nvmAvailable {
                        case true: Label("Installed", systemImage: "checkmark.circle")
                        case false: Text("Not Installed").foregroundStyle(.secondary)
                        case nil: Text("Not Checked").foregroundStyle(.secondary)
                        }
                        switch nvmAvailable {
                        case true: EmptyView()
                        case false:
                            Text("nvm manages multiple Node versions. Install it using the official guide to add or switch versions here.")
                                .font(.callout).foregroundStyle(.secondary)
                        case nil:
                            Text("Check nvm availability before managing Node versions.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
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
            NodeInstallationSheet(model: model, canInstall: nvmAvailable == true) { version in
                showsInstallation = false
                Task { await model.performDirectNodeAction(.init(action: .installNode, subject: version)) }
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
                    Button("Use for Cellar") { Task { await model.performDirectNodeAction(.init(action: .useNode, subject: item.version)) } }
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
    let install: (String) -> Void
    @StateObject private var runtime = RuntimeToolsModel()
    @State private var selectedRelease = ""
    @State private var didLoad = false
    @State private var retryTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
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
                Button("Install Node") { install(selectedRelease) }
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
