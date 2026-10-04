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
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: .general) { generalPane }
            Tab("Sources", systemImage: "network", value: .sources) {
                SourcesSettingsView(model: model)
            }
            Tab("Terminal", systemImage: "terminal", value: .terminal) {
                TerminalSettingsView(model: model)
            }
            Tab("About", systemImage: "info.circle", value: .about) {
                AboutView(updateController: updateController)
            }
        }
        .scenePadding()
        .frame(width: 640, height: 520)
        .safeAreaInset(edge: .top) {
            if let task = operationStore.activeTask {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Working on Environment")
                    Spacer()
                    Button("Cancel Task") { operationStore.cancelActiveTask() }.disabled(!task.canCancel)
                }.padding(.horizontal)
            }
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
        .formStyle(.grouped)
    }

    private var languageSelection: Binding<ApplicationLanguage> {
        Binding(get: { pendingLanguage }, set: { language in
            pendingLanguage = language
            showsRestartConfirmation = language != relaunchController.selectedLanguage
        })
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
        VStack(spacing: 16) {
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
            Link("Open Source", destination: sourceCodeURL)
            Text("Copyright © 2026 SlippinDylan Studio")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
