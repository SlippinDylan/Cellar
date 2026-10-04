import SwiftUI

struct RuntimeToolsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var runtime = RuntimeToolsModel()
    @State private var installations: [NodeInstallation] = []
    @State private var selectedRelease = ""
    var body: some View {
        Form {
            Section {
                if let node = model.node { LabeledContent("Cellar Session", value: node.summary.nodeVersion) }
                else { Text("Node Environment Unavailable") }
                if let version = installations.first(where: \.isDefault)?.version { LabeledContent("nvm Default", value: version) }
                else { Text("The nvm default cannot be resolved. Select an installed version or set a default.") }
                Text("Session changes affect Cellar only. Setting the default affects future nvm sessions.").foregroundStyle(.secondary)
                Button("Use nvm Default") { Task { await model.restoreDefaultNodeSession() } }.disabled(model.isBusy)
            } header: { Text("Node Environment") }
            Section {
                if installations.isEmpty { Text("No installed nvm Node versions were found.") }
                ForEach(installations) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(item.version).font(.body.monospaced()).textSelection(.enabled)
                            if item.isActive { Label("Current Session", systemImage: "checkmark.circle") }
                            if item.isDefault { Label("Default", systemImage: "star") }
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack { versionActions(item) }
                            VStack(alignment: .leading) { versionActions(item) }
                        }
                    }
                }
            } header: { Text("Installed Node Versions") }
            Section {
                Button("Load Official Node Versions") { Task { await runtime.refresh(model: model) } }.disabled(model.isBusy)
                if runtime.isLoading { ProgressView() }
                if let error = runtime.error { Text(error).textSelection(.enabled) }
                if !runtime.releases.isEmpty {
                    Picker("Node Version", selection: $selectedRelease) {
                        Text("Choose a Version").tag("")
                        ForEach(runtime.releases) { Text($0.version).tag($0.version) }
                    }
                    Button("Install Node") {
                        let version = selectedRelease
                        Task { await model.prepareNodeAction(.init(action: .installNode, subject: version)); if let plan = model.nodePlan { await model.executeNodePlan(confirmed: plan) } }
                    }.disabled(selectedRelease.isEmpty || model.isBusy || model.homeDashboard.nvmInstalled == false)
                }
                Link("nvm Installation Guide", destination: CatalogWebsites.nvm)
            } header: { Text("Install Node") }
        }
        .formStyle(.grouped)
        .task(id: model.refreshedAt) {
            guard !AppRuntime.isRunningTests else { return }
            installations = await model.service.runtimeInstallations(preferredVersion: model.preferredNodeVersion)
        }
    }
    @ViewBuilder private func versionActions(_ item: NodeInstallation) -> some View {
        Button("Use for Cellar") { Task { await model.prepareNodeAction(.init(action: .useNode, subject: item.version)); if let plan = model.nodePlan { await model.executeNodePlan(confirmed: plan) } } }
            .disabled(item.isActive || model.isBusy)
        Button("Set as Default…") { Task { await model.prepareNodeAction(.init(action: .setDefaultNode, subject: item.version)) } }.disabled(item.isDefault || model.isBusy)
        Button("Uninstall Node…", role: .destructive) { Task { await model.prepareNodeAction(.init(action: .uninstallNode, subject: item.version)) } }
            .disabled(!RuntimeProtection.canUninstall(item) || model.isBusy)
    }
}
