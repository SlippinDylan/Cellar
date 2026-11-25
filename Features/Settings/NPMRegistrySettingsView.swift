import SwiftUI

struct NPMRegistrySettingsView: View {
    @ObservedObject var model: AppModel
    @State private var registry = ""
    @State private var scope = ""
    @State private var scopeRegistry = ""
    @State private var scopeLayers: NPMRegistryLayers?
    @State private var scopeReadError: String?
    @State private var isReadingScope = false
    @State private var scopeReadTask: Task<Void, Never>?

    var body: some View {
        SettingsPage(fillsViewport: true) {
            npmSources
            Spacer(minLength: 0)
            EnvironmentFooterView {
                if let node = model.node {
                    LabeledContent("Target Node Version", value: node.summary.nodeVersion)
                    LabeledContent("Effective Registry", value: DiagnosticText.sanitized(node.configuration.registry))
                } else { Text("Node Environment Unavailable") }
            }
        }
        .onChange(of: scope) { _, _ in
            scopeReadTask?.cancel()
            scopeReadTask = nil
            scopeLayers = nil
            scopeReadError = nil
        }
        .onChange(of: model.nodeActionResult?.operation.operationId) { _, _ in scopeLayers = nil }
        .onChange(of: model.node?.summary) { _, _ in
            scopeReadTask?.cancel()
            scopeReadTask = nil
            scopeLayers = nil
            scopeReadError = nil
        }
        .onDisappear {
            scopeReadTask?.cancel()
            scopeReadTask = nil
        }
        .modifier(ProviderTaskPresentation(model: model, surface: .npmSources))
    }

    @ViewBuilder
    private var npmSources: some View {
        SettingsSection(title: "npm Default Registry", website: CatalogWebsites.npm, websiteTitle: "npm Website") {
            Text("Settings change the user layer. The effective Registry may come from a higher priority layer.")
                .font(.callout).foregroundStyle(.secondary)
            SettingsTextField(title: "Default Registry URL", text: $registry, prompt: "https://registry.example.com/")
            if !registry.isEmpty && SourceConfiguration.registryURL(registry) == nil {
                Text("Use a credential-free HTTPS Registry URL, or HTTP on localhost, 127.0.0.1, or [::1]. Other addresses are unsupported.")
            }
            HStack {
                Spacer()
                Button("Remove User Default", role: .destructive) { prepare(.init(action: .deleteRegistry)) }.disabled(unavailable)
                Button("Set Default Registry") { prepare(.init(action: .setRegistry, subject: registry.trimmingCharacters(in: .whitespacesAndNewlines))) }
                    .disabled(SourceConfiguration.registryURL(registry) == nil || unavailable)
            }
        }
        SettingsSection(title: "npm Scope Registry") {
            Text("Use a separate Registry for packages in a specific organization or namespace.")
                .font(.callout).foregroundStyle(.secondary)
            SettingsTextField(title: "npm Scope", text: $scope, prompt: "@company")
            if !scope.isEmpty && !SourceConfiguration.validScope(scope) { Text("Use a lowercase npm scope, such as @company.") }
            SettingsTextField(title: "Scope Registry URL", text: $scopeRegistry, prompt: "https://registry.example.com/")
            if !scopeRegistry.isEmpty && SourceConfiguration.registryURL(scopeRegistry) == nil {
                Text("Use a credential-free HTTPS Registry URL, or HTTP on localhost, 127.0.0.1, or [::1]. Other addresses are unsupported.")
            }
            HStack(spacing: 8) {
                Spacer()
                if isReadingScope { ProgressView().controlSize(.small) }
                Button("Check Effective Scope Registry") {
                    scopeReadTask?.cancel()
                    scopeReadTask = Task { await readScope() }
                }
                .disabled(!SourceConfiguration.validScope(scope) || unavailable || isReadingScope)
            }
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

    private var unavailable: Bool { model.isBusy || model.node == nil || model.nodeRefreshFailed }
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
        guard !Task.isCancelled, let node = model.node, let managers = model.managers, !model.isBusy, !model.nodeRefreshFailed, !isReadingScope else { return }
        let requestedScope = scope
        isReadingScope = true
        scopeReadError = nil
        let task = Task {
            try await model.service.scopeRegistryLayers(requestedScope, summary: node.summary, snapshot: managers)
        }
        let readOnlyID = model.operationStore.registerReadOnlyOperation(
            cancel: { task.cancel() },
            awaitCompletion: { _ = try? await task.value }
        )
        defer {
            model.operationStore.unregisterReadOnlyOperation(readOnlyID)
            isReadingScope = false
        }
        do {
            let layers = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard scope == requestedScope, !model.nodeRefreshFailed, model.node?.summary == node.summary else { return }
            scopeLayers = layers
        } catch is CancellationError {
            return
        } catch {
            guard scope == requestedScope, !model.nodeRefreshFailed, model.node?.summary == node.summary else { return }
            scopeReadError = String(localized: ActivityItemReason(error: error).message)
        }
    }
}
