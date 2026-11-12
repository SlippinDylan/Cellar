import SwiftUI
import UniformTypeIdentifiers

struct ProjectToolsView: View {
    @ObservedObject var model: AppModel
    let installations: [NodeInstallation]
    @State private var selectedDirectory: URL?
    @State private var version = ""
    @State private var currentVersion: String?
    @State private var readError: String?
    @State private var choosingDirectory = false
    @State private var isReading = false
    @State private var readRequest = UUID()
    var body: some View {
        SettingsSection(title: "Project Version") {
            HStack(spacing: 24) {
                Text("Declare the Node version a project needs in .nvmrc.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Choose Project…") { choosingDirectory = true }.disabled(model.isBusy)
                    .fixedSize()
            }
            .frame(minHeight: AppLayout.minimumControlRowHeight)
            if let selectedDirectory {
                Divider()
                LabeledContent("Selected Project", value: selectedDirectory.lastPathComponent)
                Text(selectedDirectory.path).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(selectedDirectory.path)
                if isReading { ProgressView("Reading Project Configuration…") }
                else if let currentVersion { LabeledContent("Current .nvmrc", value: currentVersion) }
                else if readError == nil { Text("This project has no .nvmrc.") }
                if let readError { Label(readError, systemImage: "exclamationmark.triangle") }
                HStack(alignment: .bottom, spacing: 12) {
                    SettingsTextField(title: "Node Version", text: $version, prompt: String(localized: "For example, v24.0.0"))
                    if !installations.isEmpty {
                        Menu("Installed Versions") {
                            ForEach(installations) { item in
                                Button(item.version) { version = item.version }
                            }
                        }.fixedSize()
                    }
                }.disabled(isReading || model.isBusy)
                Button("Save .nvmrc…") {
                    let request = NodeActionRequest(action: .writeProjectNVMRC, subject: selectedDirectory.path, value: version.trimmingCharacters(in: .whitespacesAndNewlines))
                    Task { await model.prepareNodeAction(request) }
                }.disabled(version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || readError != nil || isReading || model.isBusy)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
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
            guard let selectedDirectory, let result = model.nodeActionResult,
                  result.plan.request.action == .writeProjectNVMRC,
                  result.plan.request.subject == selectedDirectory.path else { return }
            isReading = true
            readRequest = UUID()
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
