import SwiftUI

struct DiagnosticsToolsView: View {
    @ObservedObject var model: AppModel
    @State private var showsDetails = false
    @State private var didRequestCheck = false
    @State private var isChecking = false
    var clipboard: ActivityClipboard = .live

    var body: some View {
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
            if !isChecking, model.homebrewDiagnosticReport != nil {
                Button("View Check Details…") { showsDetails = true }
            }
        }
        .sheet(isPresented: $showsDetails) {
            ActivityDiagnosticsView(store: model.activityDiagnostics, initialSelection: model.homebrewDiagnosticRecordID, clipboard: clipboard)
        }
    }
}
