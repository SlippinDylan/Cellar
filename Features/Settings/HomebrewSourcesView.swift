import SwiftUI

struct HomebrewSourcesView: View {
    @ObservedObject var model: AppModel
    @State private var tapName = ""
    @State private var showsAddTap = false
    @State private var submittedTap: String?

    var body: some View {
        SettingsPage {
            homebrewSources
        }
        .sheet(isPresented: $showsAddTap, onDismiss: prepareSubmittedTap) {
            addTapSheet
        }
        .modifier(ProviderTaskPresentation(model: model, surface: .homebrewSources))
    }

    private var homebrewSources: some View {
        SettingsSection(title: "Homebrew Taps", website: CatalogWebsites.homebrew, websiteTitle: "Homebrew Website",
                        action: .init(title: "Add Tap", isEnabled: model.homebrew?.isInstalled == true && !model.isBusy, perform: { showsAddTap = true })) {
            if let snapshot = model.homebrew?.snapshot {
                if snapshot.sectionErrors[.taps] != nil {
                    Text("Homebrew Tap Information Unavailable")
                } else if snapshot.taps.isEmpty {
                    Text("No Additional Taps").foregroundStyle(.secondary)
                }
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
        .constrainedSheetWidth(460)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
    }

    private func prepareSubmittedTap() {
        guard let name = submittedTap else { return }
        submittedTap = nil
        Task { await model.prepareHomebrewAddTap(name) }
    }
}
