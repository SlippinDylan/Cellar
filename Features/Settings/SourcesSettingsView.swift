import SwiftUI

struct SourcesSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var tapName = ""
    @State private var showsAddTap = false
    @State private var submittedTap: String?
    @State private var registry = ""
    @State private var scope = ""
    @State private var scopeRegistry = ""
    @State private var scopeLayers: NPMRegistryLayers?
    @State private var scopeReadError: String?
    var body: some View {
        SettingsPage {
            homebrewSources
            npmSources
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .onChange(of: scope) { _, _ in scopeLayers = nil; scopeReadError = nil }
        .onChange(of: model.nodeActionResult?.operation.operationId) { _, _ in scopeLayers = nil }
        .onChange(of: model.node?.summary.activityEnvironment) { _, _ in
            scopeLayers = nil
            scopeReadError = nil
        }
        .sheet(isPresented: $showsAddTap, onDismiss: prepareSubmittedTap) {
            addTapSheet
        }
        .modifier(ProviderTaskPresentation(model: model, surface: .sources))
    }

    private var homebrewSources: some View {
        SettingsSection(title: "Homebrew Taps", website: CatalogWebsites.homebrew, websiteTitle: "Homebrew Website",
                        action: .init(title: "Add Tap", isEnabled: model.homebrew?.isInstalled == true && !model.isBusy, perform: { showsAddTap = true })) {
            if let snapshot = model.homebrew?.snapshot {
                if snapshot.sectionErrors[.taps] != nil { Text("Homebrew Tap Information Unavailable") }
                VStack(spacing: 0) {
                    ForEach(snapshot.taps) { tap in
                        HStack {
                            Text(tap.name).textSelection(.enabled)
                            Spacer()
                            Button("Remove Tap", role: .destructive) { Task { await model.prepareHomebrewRemoveTap(tap.name) } }
                                .disabled(model.isBusy)
                        }
                        .frame(minHeight: AppLayout.minimumControlRowHeight)
                        if tap.id != snapshot.taps.last?.id { Divider() }
                    }
                }
            } else { Text("Homebrew Path Unavailable") }

        }
    }

    @ViewBuilder
    private var npmSources: some View {
        SettingsSection(title: "npm Registry", website: CatalogWebsites.npm, websiteTitle: "npm Website", detail: model.node.map { "Node \($0.summary.nodeVersion) · npm \($0.summary.npmVersion)" }) {
            if let node = model.node {
                registryLayer("Effective Registry", node.configuration.registry)
                Divider()
                Text("Configuration Sources").font(.headline)
                registryLayer("User", node.configuration.userRegistry)
                registryLayer("Project", node.configuration.projectRegistry)
                registryLayer("Global", node.configuration.globalRegistry)
            } else { Text("Node Environment Unavailable") }
        }
        SettingsSection(title: "Change User Registry") {
            Text("Settings change the user layer. The effective Registry may come from a higher priority layer.")
                .font(.callout).foregroundStyle(.secondary)
            SettingsTextField(title: "Default Registry URL", text: $registry, prompt: "https://registry.example.com/")
            if !registry.isEmpty && SourceConfiguration.registryURL(registry) == nil {
                Text("Enter a credential-free HTTP or HTTPS Registry URL.")
            }
            HStack {
                Spacer()
                Button("Remove User Default", role: .destructive) { prepare(.init(action: .deleteRegistry)) }.disabled(unavailable)
                Button("Set Default Registry") { prepare(.init(action: .setRegistry, subject: registry.trimmingCharacters(in: .whitespacesAndNewlines))) }
                    .disabled(SourceConfiguration.registryURL(registry) == nil || unavailable)
            }
        }
        SettingsSection(title: "Scoped npm Registries") {
            SettingsTextField(title: "npm Scope", text: $scope, prompt: "@company")
            if !scope.isEmpty && !SourceConfiguration.validScope(scope) { Text("Use a lowercase npm scope, such as @company.") }
            SettingsTextField(title: "Scope Registry URL", text: $scopeRegistry, prompt: "https://registry.example.com/")
            if !scopeRegistry.isEmpty && SourceConfiguration.registryURL(scopeRegistry) == nil {
                Text("Enter a credential-free HTTP or HTTPS Registry URL.")
            }
            Button("Check Effective Scope Registry") { Task { await readScope() } }
                .disabled(!SourceConfiguration.validScope(scope) || unavailable)
                .frame(maxWidth: .infinity, alignment: .trailing)
            if let scopeLayers {
                registryLayer("Effective Scope Registry", scopeLayers.effective)
                registryLayer("User", scopeLayers.user)
                registryLayer("Project", scopeLayers.project)
                registryLayer("Global", scopeLayers.global)
            }
            if let scopeReadError { Label(scopeReadError, systemImage: "exclamationmark.triangle") }
            HStack {
                Spacer()
                Button("Remove User Scope", role: .destructive) { prepare(.init(action: .deleteScopeRegistry, subject: scope)) }
                    .disabled(!SourceConfiguration.validScope(scope) || unavailable)
                Button("Set Scope Registry") { prepare(.init(action: .setScopeRegistry, subject: scope, value: scopeRegistry.trimmingCharacters(in: .whitespacesAndNewlines))) }
                    .disabled(!SourceConfiguration.validScope(scope) || SourceConfiguration.registryURL(scopeRegistry) == nil || unavailable)
            }
        }
    }

    private var addTapSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Tap").font(.title2.bold())
            SettingsTextField(title: "Tap Name", text: $tapName, prompt: "owner/repository")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { showsAddTap = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add Tap") {
                    submittedTap = tapName.trimmingCharacters(in: .whitespacesAndNewlines)
                    showsAddTap = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!ActivitySummarySanitizer.validHomebrewTap(tapName.trimmingCharacters(in: .whitespacesAndNewlines)) || model.homebrew?.isInstalled != true || model.isBusy)
            }
        }
        .padding(24)
        .frame(width: 460)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
    }

    private func prepareSubmittedTap() {
        guard let name = submittedTap else { return }
        submittedTap = nil
        Task { await model.prepareHomebrewAddTap(name) }
    }

    private var unavailable: Bool { model.isBusy || model.node == nil }
    private func prepare(_ request: NodeActionRequest) { Task { await model.prepareNodeAction(request) } }
    private func registryLayer(_ title: LocalizedStringResource, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(title)
            Spacer(minLength: 0)
            if value.isEmpty || value == "undefined" || value == "null" {
                Text("Not Set").foregroundStyle(.secondary)
            } else {
                Text(DiagnosticText.sanitized(value))
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
        .frame(minHeight: AppLayout.minimumInfoRowHeight)
    }
    private func readScope() async {
        guard let node = model.node, let managers = model.managers, !model.isBusy else { return }
        let requestedScope = scope
        let environment = NodeEnvironmentContext(identifier: node.summary.nodePath, nodeVersion: node.summary.nodeVersion, npmVersion: node.summary.npmVersion)
        let id = model.operationStore.begin()
        defer { model.operationStore.end(id) }
        scopeReadError = nil
        do {
            let layers = try await model.operationStore.performCancellable(operationID: id) { try await model.service.scopeRegistryLayers(requestedScope, environment: environment, snapshot: managers) }
            guard scope == requestedScope, model.node?.summary.activityEnvironment == environment else { return }
            scopeLayers = layers
        } catch {
            guard scope == requestedScope, model.node?.summary.activityEnvironment == environment else { return }
            scopeReadError = String(localized: "The scope Registry could not be read. Refresh and try again.")
        }
    }
}
