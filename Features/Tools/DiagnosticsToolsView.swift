import SwiftUI

struct DiagnosticsToolsView: View {
    @ObservedObject var model: AppModel
    @State private var nodePath = ""
    @State private var showsDetails = false
    var clipboard: ActivityClipboard = .live
    var body: some View {
        Form {
            Section {
                Button("Check Homebrew Health") { Task { await model.diagnoseHomebrew() } }.disabled(model.homebrew?.isInstalled != true || model.isBusy)
                if let report = model.homebrewDiagnosticReport {
                    if report.command.terminationStatus == 0 { Label("Homebrew Reports No Issues", systemImage: "checkmark.circle") }
                    else { Label("Homebrew Reported Issues", systemImage: "exclamationmark.triangle") }
                    Text("Open diagnostics for Homebrew’s detailed findings.").foregroundStyle(.secondary)
                    Button("Show Diagnostics…") { showsDetails = true }
                }
            } header: { Text("Homebrew Health") }
            Section {
                if let snapshot = model.homebrew?.snapshot {
                    LabeledContent("Homebrew Executable", value: snapshot.executablePath)
                    LabeledContent("Homebrew Prefix", value: snapshot.configuration.prefix)
                    LabeledContent("Homebrew PATH", value: snapshot.controlledPath)
                    if !snapshot.sectionErrors.isEmpty { Text("Some Homebrew information could not be read.") }
                } else { Text("Homebrew Path Unavailable") }
                if let node = model.node {
                    LabeledContent("Node Executable", value: node.summary.nodePath)
                    LabeledContent("npm Executable", value: node.summary.npmPath)
                    LabeledContent("Global npm Directory", value: node.summary.globalRoot)
                } else { Text("Node Environment Unavailable") }
                if !nodePath.isEmpty { LabeledContent("Node PATH", value: nodePath) }
                if let shell = model.shell { LabeledContent("Shell Configuration", value: shell.zshrcPath) }
                else { Text("Terminal State Unavailable") }
            } header: { Text("Controlled Paths") }
        }
        .formStyle(.grouped)
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
