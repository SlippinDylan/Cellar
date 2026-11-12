import SwiftUI

struct DiagnosticsToolsView: View {
    @ObservedObject var model: AppModel
    @State private var nodePath = ""
    @State private var showsDetails = false
    @State private var didRequestCheck = false
    @State private var isChecking = false
    var clipboard: ActivityClipboard = .live

    var body: some View {
        SettingsPage {
            SettingsSection(title: "Homebrew Health", website: CatalogWebsites.homebrew, websiteTitle: "Homebrew Website") {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        if isChecking {
                            Text("Checking Homebrew…")
                        } else if let report = model.homebrewDiagnosticReport {
                            if report.command.terminationStatus == 0 {
                                Label("Homebrew Reports No Issues", systemImage: "checkmark.circle")
                            } else {
                                Label("Homebrew Reported Issues", systemImage: "exclamationmark.triangle")
                            }
                        } else if didRequestCheck, model.homebrewOperationError != nil {
                            Label("Homebrew Check Failed", systemImage: "exclamationmark.triangle")
                        } else {
                            Text("Not Checked").foregroundStyle(.secondary)
                        }
                        Text("Check Homebrew for configuration and installation issues.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Check Homebrew Health") {
                        Task {
                            didRequestCheck = true
                            isChecking = true
                            await model.diagnoseHomebrew()
                            isChecking = false
                        }
                    }.disabled(model.homebrew?.isInstalled != true || model.isBusy)
                }
                .frame(minHeight: AppLayout.minimumDescribedRowHeight)
            }
            SettingsSection(title: "Environment Details") {
                VStack(spacing: 8) {
                    if let snapshot = model.homebrew?.snapshot {
                        LabeledContent("Homebrew Executable", value: snapshot.executablePath)
                        Divider()
                        LabeledContent("Homebrew Prefix", value: snapshot.configuration.prefix)
                        Divider()
                        LabeledContent("Homebrew PATH", value: snapshot.controlledPath)
                        if !snapshot.sectionErrors.isEmpty { Text("Some Homebrew information could not be read.") }
                    } else { Text("Homebrew Path Unavailable") }
                    Divider()
                    if let node = model.node {
                        LabeledContent("Node Executable", value: node.summary.nodePath)
                        Divider()
                        LabeledContent("npm Executable", value: node.summary.npmPath)
                        Divider()
                        LabeledContent("Global npm Directory", value: node.summary.globalRoot)
                    } else { Text("Node Environment Unavailable") }
                    Divider()
                    if !nodePath.isEmpty {
                        LabeledContent("Node PATH", value: nodePath)
                        Divider()
                    }
                    if let shell = model.shell { LabeledContent("Shell Configuration", value: shell.zshrcPath) }
                    else { Text("Terminal State Unavailable") }
                }
                Divider()
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Current Session Diagnostics")
                        Text("Technical output is kept only for this App session and is not written to log files.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Show Diagnostics…") { showsDetails = true }
                }
                .frame(minHeight: AppLayout.minimumDescribedRowHeight)
            }
        }
        .textSelection(.enabled)
        .task(id: model.refreshedAt) {
            guard !AppRuntime.isRunningTests else { return }
            nodePath = await model.service.controlledNodePath(preferredVersion: model.preferredNodeVersion)
        }
        .sheet(isPresented: $showsDetails) {
            ActivityDiagnosticsView(store: model.activityDiagnostics, initialSelection: model.homebrewDiagnosticRecordID, clipboard: clipboard)
        }
    }
}
