import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var relaunchController: ApplicationRelaunchController
    @ObservedObject var operationStore: OperationStore
    @State private var pendingLanguage: ApplicationLanguage
    @State private var showsRestartConfirmation = false
    @State private var showsRestartBlocked = false

    init(model: AppModel, relaunchController: ApplicationRelaunchController) {
        self.model = model
        self.relaunchController = relaunchController
        operationStore = model.operationStore
        _pendingLanguage = State(initialValue: relaunchController.selectedLanguage)
    }

    var body: some View {
        Group {
            switch model.selectedSettingsCategory {
            case .general: generalPane
            case .environment: EnvironmentInformationView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(relaunchController.$selectedLanguage) { language in
            pendingLanguage = language
        }
        .alert("Restart Cellar to Change Language?", isPresented: $showsRestartConfirmation) {
            Button("Restart Now") {
                if !relaunchController.changeLanguage(pendingLanguage) {
                    pendingLanguage = relaunchController.selectedLanguage
                    showsRestartBlocked = true
                }
            }
            .disabled(operationStore.hasActiveOperations)
            Button("Cancel", role: .cancel) { pendingLanguage = relaunchController.selectedLanguage }
        } message: {
            Text("Cellar will quit and reopen using the selected language.")
        }
        .alert("Unable to Restart", isPresented: $showsRestartBlocked) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Wait for the current task to finish before changing the language.")
        }
    }

    private var generalPane: some View {
        SettingsPage {
            SettingsSection(title: "Language") {
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Language")
                        Text(operationStore.hasActiveOperations
                             ? LocalizedStringResource("Wait for the current task to finish before changing the language.")
                             : LocalizedStringResource("Changing the language restarts Cellar."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Picker("Language", selection: languageSelection) {
                        ForEach(ApplicationLanguage.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    .labelsHidden()
                    .buttonSizing(.flexible)
                    .frame(width: 180)
                    .disabled(operationStore.hasActiveOperations)
                }
                .frame(minHeight: AppLayout.minimumDescribedRowHeight)
            }
            FullDiskAccessSettingsView()
            if let logStore = model.logStore { LoggingSettingsView(store: logStore, diagnostics: model.activityDiagnostics) }
        }
    }

    private var languageSelection: Binding<ApplicationLanguage> {
        Binding(get: { pendingLanguage }, set: { language in
            pendingLanguage = language
            showsRestartConfirmation = language != relaunchController.selectedLanguage
        })
    }
}
