import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    let updateController: ApplicationUpdateController
    @ObservedObject var relaunchController: ApplicationRelaunchController
    @ObservedObject var operationStore: OperationStore
    @AppStorage("settings.pane") private var pane: SettingsPane = .general
    @State private var pendingLanguage: ApplicationLanguage
    @State private var showsRestartConfirmation = false
    @State private var showsRestartBlocked = false

    init(model: AppModel, updateController: ApplicationUpdateController, relaunchController: ApplicationRelaunchController,
         defaults: UserDefaults = .standard) {
        self.model = model
        self.updateController = updateController
        self.relaunchController = relaunchController
        operationStore = model.operationStore
        _pane = AppStorage(wrappedValue: .general, "settings.pane", store: defaults)
        _pendingLanguage = State(initialValue: relaunchController.selectedLanguage)
    }

    var body: some View {
        Group {
            switch pane {
            case .general: generalPane
            case .sources: SourcesSettingsView(model: model)
            case .terminal: TerminalSettingsView(model: model)
            case .about: AboutView(updateController: updateController)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusedSceneValue(\.settingsPane, $pane)
        .onAppear { applyPendingSettingsPane() }
        .onChange(of: model.pendingSettingsPane) { _, requestedPane in
            if requestedPane != nil { applyPendingSettingsPane() }
        }
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
            Text("Finish or cancel the current task before changing the language.")
        }
    }

    private var generalPane: some View {
        Form {
            Picker("Language", selection: languageSelection) {
                ForEach(ApplicationLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
            .disabled(operationStore.hasActiveOperations)
            Text(operationStore.hasActiveOperations
                 ? LocalizedStringResource("Finish or cancel the current task before changing the language.")
                 : LocalizedStringResource("Changing the language restarts Cellar."))
                .foregroundStyle(.secondary)
        }
        .formStyle(AppFormStyle())
    }

    private var languageSelection: Binding<ApplicationLanguage> {
        Binding(get: { pendingLanguage }, set: { language in
            pendingLanguage = language
            showsRestartConfirmation = language != relaunchController.selectedLanguage
        })
    }

    private func applyPendingSettingsPane() {
        if let requestedPane = model.consumePendingSettingsPane() {
            pane = requestedPane
        }
    }
}

private struct SettingsPaneKey: FocusedValueKey { typealias Value = Binding<SettingsPane> }

extension FocusedValues {
    var settingsPane: Binding<SettingsPane>? {
        get { self[SettingsPaneKey.self] }
        set { self[SettingsPaneKey.self] = newValue }
    }
}

extension SettingsPane {
    var title: LocalizedStringResource {
        switch self {
        case .general: LocalizedStringResource("General")
        case .sources: LocalizedStringResource("Sources")
        case .terminal: LocalizedStringResource("Terminal")
        case .about: LocalizedStringResource("About")
        }
    }
}

struct AboutView: View {
    let updateController: ApplicationUpdateController

    private var sourceCodeURL: URL {
        guard let url = URL(string: "https://github.com/SlippinDylan/Cellar") else {
            preconditionFailure("The source code URL must be valid")
        }
        return url
    }

    private var version: String {
        guard let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            preconditionFailure("The app bundle must include version metadata")
        }
        return "\(marketing) (\(build))"
    }

    private var updateChannel: LocalizedStringResource {
        switch updateController.updateChannel {
        case "stable": LocalizedStringResource("Stable")
        case "beta": LocalizedStringResource("Beta")
        case "alpha": LocalizedStringResource("Alpha")
        default: preconditionFailure("Unsupported update channel")
        }
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                aboutContent
                    .frame(maxWidth: .infinity, minHeight: max(0, viewport.size.height - AppLayout.spacing * 2))
            }
            .contentMargins(AppLayout.spacing, for: .scrollContent)
        }
    }

    private var aboutContent: some View {
        VStack(spacing: AppLayout.spacing) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text("Cellar").font(.title.bold())
            Text("Version \(version)").foregroundStyle(.secondary)
            LabeledContent("Update Channel") { Text(updateChannel) }
                .fixedSize()
            Button("Check for Updates…") { updateController.checkForUpdates() }
                .disabled(!updateController.canCheckForUpdates)
            WebsiteLink(destination: sourceCodeURL, title: LocalizedStringResource("Open Source"))
            Text("Copyright © 2026 SlippinDylan Studio")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
