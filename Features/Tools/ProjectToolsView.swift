import SwiftUI
import UniformTypeIdentifiers

struct ProjectToolsView: View {
    @ObservedObject var model: AppModel
    @State private var selectedDirectory: URL?
    @State private var version = ""
    @State private var currentVersion: String?
    @State private var readError: String?
    @State private var choosingDirectory = false
    var body: some View {
        Form {
            Section {
                Text("Select a project to read or change its .nvmrc. Cellar does not search other projects.").foregroundStyle(.secondary)
                Button("Choose Project…") { choosingDirectory = true }.disabled(model.isBusy)
                if let selectedDirectory {
                    LabeledContent("Selected Project") { Text(selectedDirectory.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(selectedDirectory.path) }
                    if let currentVersion { LabeledContent("Current .nvmrc", value: currentVersion) }
                    else if readError == nil { Text("This project has no .nvmrc.") }
                    if let readError { Label(readError, systemImage: "exclamationmark.triangle") }
                    TextField("Node Version", text: $version, prompt: Text("For example, v24.0.0"))
                    Button("Save .nvmrc…") {
                        let request = NodeActionRequest(action: .writeProjectNVMRC, subject: selectedDirectory.path, value: version.trimmingCharacters(in: .whitespacesAndNewlines))
                        Task { await model.prepareNodeAction(request) }
                    }.disabled(version.isEmpty || readError != nil || model.isBusy)
                }
            } header: { Text("Project Node Version") }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosingDirectory, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            do {
                let urls = try result.get()
                guard let url = urls.first else { return }
                selectedDirectory = url
                model.dismissNodePlan()
                Task { await readProject(url) }
            } catch { readError = error.localizedDescription }
        }
        .onChange(of: model.nodeActionResult?.operation.operationId) { _, _ in
            if let selectedDirectory { Task { await readProject(selectedDirectory) } }
        }
    }
    private func readProject(_ url: URL) async {
        readError = nil
        currentVersion = nil
        do {
            let value = try await ProjectConfigurationService().readNVMRC(in: url)
            guard selectedDirectory == url else { return }
            currentVersion = value
            version = value ?? ""
        } catch { readError = error.localizedDescription }
    }
}
