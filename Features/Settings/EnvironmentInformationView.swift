import SwiftUI

struct EnvironmentInformationView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var nodePath: String?

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: 20) {
                Text("Environment Information")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
                receiptSection("Homebrew") {
                    if let homebrew = model.homebrew {
                        LabeledContent("Status", value: String(localized: homebrew.isInstalled ? "Installed" : "Not Installed"))
                        if let version = homebrew.version { LabeledContent("Version", value: version) }
                        if let executable = homebrew.executablePath { pathRow("Executable", executable) }
                        if let snapshot = homebrew.snapshot {
                            if snapshot.sectionErrors[.configuration] == nil {
                                pathRow("Installation Directory", snapshot.configuration.prefix)
                                pathRow("Repository Directory", snapshot.configuration.repository)
                                pathRow("Cache Directory", snapshot.configuration.cache)
                                pathRow("Cellar Directory", snapshot.configuration.cellar)
                            }
                            pathList("PATH", snapshot.controlledPath)
                            if !snapshot.sectionErrors.isEmpty { Text("Some Homebrew information could not be read.") }
                        }
                    } else {
                        Text(model.homebrewRefreshFailed ? LocalizedStringResource("Homebrew Path Unavailable") : LocalizedStringResource("Not Checked"))
                    }
                    if model.homebrewRefreshFailed { Text("Local Homebrew refresh failed. Previously read information is retained.") }
                }
                receiptSection("Node.js") {
                    if let node = model.node {
                        LabeledContent("Node Version", value: node.summary.nodeVersion)
                        LabeledContent("npm Version", value: node.summary.npmVersion)
                        pathRow("Node Executable", node.summary.nodePath)
                        pathRow("npm Executable", node.summary.npmPath)
                        pathRow("Global Prefix", node.summary.globalPrefix)
                        pathRow("Global Directory", node.summary.globalRoot)
                        pathRow("Cache Directory", node.configuration.cache)
                    } else {
                        Text(model.nodeRefreshFailed ? LocalizedStringResource("Node Environment Unavailable") : LocalizedStringResource("Not Checked"))
                    }
                    if let nodePath { pathList("PATH", nodePath) }
                    if model.nodeRefreshFailed { Text("Local Node refresh failed. Previously read information is retained.") }
                }
                receiptSection("npm Registry") {
                    if let node = model.node {
                        registryRow("Effective Registry", node.configuration.registry)
                        registryRow("User", node.configuration.userRegistry)
                        registryRow("Project", node.configuration.projectRegistry)
                        registryRow("Global", node.configuration.globalRegistry)
                    } else {
                        Text("Node Environment Unavailable")
                    }
                }
                receiptSection("nvm") {
                    LabeledContent("Status", value: String(localized: nvmStatus))
                    if let node = model.node {
                        LabeledContent("Default Version", value: node.installations.first(where: \.isDefault)?.version ?? String(localized: "Unresolved"))
                        ForEach(node.installations) { installation in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: installation.version).foregroundStyle(.secondary)
                                Text(verbatim: installation.directory)
                                    .font(.system(.callout, design: .monospaced))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if node.maintenanceError != nil { Text("Some maintenance information could not be read.") }
                    }
                }
                receiptSection("Terminal") {
                    if let shell = model.shell {
                        if let version = shell.zshVersion { LabeledContent("Zsh Version", value: version) }
                        LabeledContent("Oh My Zsh", value: String(localized: shell.ohMyZshInstalled ? "Installed" : "Not Installed"))
                        LabeledContent("Configuration File", value: String(localized: shell.zshrcExists ? "Available" : "Not Found"))
                        pathRow("Shell Configuration", shell.zshrcPath)
                        if shell.ohMyZshInstalled {
                            pathRow("Oh My Zsh Directory", shell.ohMyZshPath)
                            LabeledContent("Local Theme", value: shell.currentTheme)
                            pathRow("Active Plugins", shell.activePlugins.joined(separator: ", "))
                            pathRow("Custom Plugins", shell.installedCustomPlugins.joined(separator: ", "))
                        }
                        if model.shellRefreshFailed {
                            Text("Local Terminal refresh failed. Previously read information is retained.")
                        }
                    } else {
                        Text(model.shellRefreshFailed ? LocalizedStringResource("Terminal State Unavailable") : LocalizedStringResource("Not Checked"))
                    }
                }
            }
            .font(.callout)
            .labeledContentStyle(ReceiptRowStyle())
            .textSelection(.enabled)
            .padding(.horizontal, 28)
            .padding(.vertical, 32)
            .frame(maxWidth: 600)
            .background(Color(nsColor: .controlBackgroundColor), in: ReceiptPaper())
            .overlay {
                ReceiptPaper().stroke(.primary.opacity(contrast == .increased ? 0.35 : 0.1), lineWidth: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
        .task(id: model.refreshedAt) {
            guard !AppRuntime.isRunningTests else { return }
            nodePath = await model.service.controlledNodePath(preferredVersion: model.preferredNodeVersion)
        }
    }

    private var nvmStatus: LocalizedStringResource {
        return switch model.nvmInstalled {
        case true: "Installed"
        case false: "Not Installed"
        case nil: "Not Checked"
        }
    }

    private func receiptSection<Content: View>(_ title: LocalizedStringResource, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ReceiptSeparator()
                .stroke(.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(height: 1)
                .accessibilityHidden(true)
            Text(title)
                .font(.callout.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 6, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pathRow(_ title: LocalizedStringResource, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.system(.callout, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private func pathList(_ title: LocalizedStringResource, _ value: String) -> some View {
        pathRow(title, value.split(separator: ":", omittingEmptySubsequences: false).joined(separator: "\n"))
    }

    private func registryRow(_ title: LocalizedStringResource, _ value: String) -> some View {
        pathRow(title, value.isEmpty || value == "undefined" || value == "null"
                ? String(localized: "Not Set") : DiagnosticText.sanitized(value))
    }
}

private struct ReceiptRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            configuration.label.foregroundStyle(.secondary)
            Spacer(minLength: 0)
            configuration.content
                .font(.system(.callout, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ReceiptSeparator: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

private struct ReceiptPaper: Shape {
    func path(in rect: CGRect) -> Path {
        let teeth = max(1, Int(rect.width / 12))
        let step = rect.width / CGFloat(teeth)
        let depth: CGFloat = 4
        return Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + depth))
            for index in 0..<teeth {
                let x = rect.minX + CGFloat(index) * step
                path.addLine(to: CGPoint(x: x + step / 2, y: rect.minY))
                path.addLine(to: CGPoint(x: x + step, y: rect.minY + depth))
            }
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - depth))
            for index in (0..<teeth).reversed() {
                let x = rect.minX + CGFloat(index) * step
                path.addLine(to: CGPoint(x: x + step / 2, y: rect.maxY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY - depth))
            }
            path.closeSubpath()
        }
    }
}

struct EnvironmentFooterView<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 2) { content }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
            .labeledContentStyle(EnvironmentFooterRowStyle())
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
    }
}

private struct EnvironmentFooterRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.label
            configuration.content
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
