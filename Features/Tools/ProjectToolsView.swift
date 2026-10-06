import SwiftUI
import UniformTypeIdentifiers

struct ProjectToolsView: View {
    @ObservedObject var model: AppModel
    @State private var selectedDirectory: URL?
    @State private var version = ""
    @State private var currentVersion: String?
    @State private var readError: String?
    @State private var choosingDirectory = false
    @State private var isReading = false
    @State private var readRequest = UUID()
    var body: some View {
        Form {
            Section {
                Text("Select a project to read or change its .nvmrc. Cellar does not search other projects.").foregroundStyle(.secondary)
                Button("Choose Project…") { choosingDirectory = true }.disabled(model.isBusy)
                if let selectedDirectory {
                    LabeledContent("Selected Project") { Text(selectedDirectory.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(selectedDirectory.path) }
                    if isReading { ProgressView("Reading Project Configuration…") }
                    else if let currentVersion { LabeledContent("Current .nvmrc", value: currentVersion) }
                    else if readError == nil { Text("This project has no .nvmrc.") }
                    if let readError { Label(readError, systemImage: "exclamationmark.triangle") }
                    TextField("Node Version", text: $version, prompt: Text("For example, v24.0.0"))
                    Button("Save .nvmrc…") {
                        let request = NodeActionRequest(action: .writeProjectNVMRC, subject: selectedDirectory.path, value: version.trimmingCharacters(in: .whitespacesAndNewlines))
                        Task { await model.prepareNodeAction(request) }
                    }.disabled(version.isEmpty || readError != nil || isReading || model.isBusy)
                }
            } header: { Text("Project Node Version") }
        }
        .formStyle(AppFormStyle())
        .fileImporter(isPresented: $choosingDirectory, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            do {
                let urls = try result.get()
                guard let url = urls.first else { return }
                selectedDirectory = url
                currentVersion = nil
                version = ""
                isReading = true
                readRequest = UUID()
                model.dismissNodePlan()
            } catch { readError = model.failureMessage(error) }
        }
        .onChange(of: model.nodeActionResult?.operation.operationId) { _, _ in
            if selectedDirectory != nil { isReading = true; readRequest = UUID() }
        }
        .task(id: readRequest) {
            if let selectedDirectory { await readProject(selectedDirectory) }
        }
    }
    private func readProject(_ url: URL) async {
        let request = readRequest
        isReading = true
        defer { if readRequest == request { isReading = false } }
        readError = nil
        currentVersion = nil
        do {
            let value = try await ProjectConfigurationService().readNVMRC(in: url)
            guard selectedDirectory == url, readRequest == request, !Task.isCancelled else { return }
            currentVersion = value
            version = value ?? ""
        } catch {
            guard selectedDirectory == url, readRequest == request, !Task.isCancelled else { return }
            readError = model.failureMessage(error)
        }
    }
}
