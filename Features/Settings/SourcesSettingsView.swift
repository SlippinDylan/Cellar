import SwiftUI

struct SourcesSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var tapName = ""
    @State private var registry = ""
    @State private var scope = ""
    @State private var scopeRegistry = ""
    @State private var scopeLayers: NPMRegistryLayers?
    @State private var scopeReadError: String?
    var body: some View {
        Form {
            Section {
                if let snapshot = model.homebrew?.snapshot {
                    if snapshot.sectionErrors[.taps] != nil { Text("Homebrew Tap Information Unavailable") }
                    ForEach(snapshot.taps) { tap in
                        HStack {
                            Text(tap.name).textSelection(.enabled)
                            Spacer()
                            Button("Remove Tap…", role: .destructive) { Task { await model.prepareHomebrewRemoveTap(tap.name) } }.disabled(model.isBusy)
                        }
                    }
                } else { Text("Homebrew Path Unavailable") }
                TextField("Tap Name", text: $tapName, prompt: Text("owner/repository"))
                Button("Add Tap…") { let name = tapName.trimmingCharacters(in: .whitespacesAndNewlines); Task { await model.prepareHomebrewAddTap(name) } }
                    .disabled(tapName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.homebrew?.isInstalled != true || model.isBusy)
            } header: { Text("Homebrew Taps") }
            Section {
                if let node = model.node {
                    Text("Node Environment: \(node.summary.nodeVersion) · npm \(node.summary.npmVersion)")
                    LabeledContent("Effective Registry", value: DiagnosticText.sanitized(node.configuration.registry))
                    registryLayer("User", node.configuration.userRegistry)
                    registryLayer("Project", node.configuration.projectRegistry)
                    registryLayer("Global", node.configuration.globalRegistry)
                    Text("Settings change the user layer. The effective Registry may come from a higher priority layer.").foregroundStyle(.secondary)
                } else { Text("Node Environment Unavailable") }
                TextField("Default Registry URL", text: $registry, prompt: Text("https://registry.example.com/"))
                if !registry.isEmpty && SourceConfiguration.registryURL(registry) == nil { Text("Enter a credential-free HTTP or HTTPS Registry URL.") }
                HStack {
                    Button("Set Default Registry…") { prepare(.init(action: .setRegistry, subject: registry.trimmingCharacters(in: .whitespacesAndNewlines))) }
                        .disabled(SourceConfiguration.registryURL(registry) == nil || unavailable)
                    Button("Remove User Default…", role: .destructive) { prepare(.init(action: .deleteRegistry)) }.disabled(unavailable)
                }
            } header: { Text("Default npm Registry") }
            Section {
                TextField("npm Scope", text: $scope, prompt: Text("@company"))
                if !scope.isEmpty && !SourceConfiguration.validScope(scope) { Text("Use a lowercase npm scope, such as @company.") }
                TextField("Scope Registry URL", text: $scopeRegistry, prompt: Text("https://registry.example.com/"))
                if !scopeRegistry.isEmpty && SourceConfiguration.registryURL(scopeRegistry) == nil { Text("Enter a credential-free HTTP or HTTPS Registry URL.") }
                Button("Check Effective Scope Registry") { Task { await readScope() } }.disabled(!SourceConfiguration.validScope(scope) || unavailable)
                if let scopeLayers {
                    registryLayer("Effective Scope Registry", scopeLayers.effective)
                    registryLayer("User", scopeLayers.user)
                    registryLayer("Project", scopeLayers.project)
                    registryLayer("Global", scopeLayers.global)
                }
                if let scopeReadError { Label(scopeReadError, systemImage: "exclamationmark.triangle") }
                HStack {
                    Button("Set Scope Registry…") { prepare(.init(action: .setScopeRegistry, subject: scope, value: scopeRegistry.trimmingCharacters(in: .whitespacesAndNewlines))) }
                        .disabled(!SourceConfiguration.validScope(scope) || SourceConfiguration.registryURL(scopeRegistry) == nil || unavailable)
                    Button("Remove User Scope…", role: .destructive) { prepare(.init(action: .deleteScopeRegistry, subject: scope)) }
                        .disabled(!SourceConfiguration.validScope(scope) || unavailable)
                }
            } header: { Text("Scope npm Registry") }
        }
        .formStyle(AppFormStyle())
        .onChange(of: scope) { _, _ in scopeLayers = nil; scopeReadError = nil }
        .onChange(of: model.nodeActionResult?.operation.operationId) { _, _ in scopeLayers = nil }
        .modifier(ProviderTaskPresentation(model: model, surface: .sources))
    }
    private var unavailable: Bool { model.isBusy || model.node == nil }
    private func prepare(_ request: NodeActionRequest) { Task { await model.prepareNodeAction(request) } }
    private func registryLayer(_ title: LocalizedStringResource, _ value: String) -> some View {
        LabeledContent { if value.isEmpty || value == "undefined" || value == "null" { Text("Not Set") } else { Text(DiagnosticText.sanitized(value)).textSelection(.enabled) } } label: { Text(title) }
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
            guard scope == requestedScope else { return }
            scopeLayers = layers
        } catch { scopeReadError = String(localized: "The scope Registry could not be read. Refresh and try again.") }
    }
}
