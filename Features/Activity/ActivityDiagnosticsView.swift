import SwiftUI

struct ActivityDiagnosticsView: View {
    @ObservedObject var store: ActivityDiagnosticsStore
    let initialSelection: UUID?
    let clipboard: ActivityClipboard
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var selection: UUID?
    @State private var copyFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Current Session Diagnostics").font(.title2.bold())
            Text("Diagnostics may contain sensitive information. Review before sharing; redaction cannot recognize every secret.").foregroundStyle(.secondary)
            if store.records.isEmpty {
                ContentUnavailableView("No Session Diagnostics", systemImage: "stethoscope", description: Text("Technical output is kept only for this App session. Restored history contains summaries only."))
            } else {
                VSplitView {
                    Table(store.records, selection: $selection) {
                        TableColumn("Operation") { record in Text(ActivityRenderer(locale: locale).operation(record.operation)) }
                        TableColumn("Scope") { record in Text(ActivityRenderer(locale: locale).scope(record.scope)) }
                        TableColumn("Time") { record in Text(record.date, format: .dateTime.hour().minute().second()) }
                    }.frame(minHeight: 120)
                    if let record = store.records.first(where: { $0.id == selection }) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                diagnosticSection("Technical Details", text: record.detail)
                                diagnosticSection("Command", text: record.command)
                                diagnosticSection("Standard Output", text: record.standardOutput)
                                diagnosticSection("Standard Error", text: record.standardError)
                                if record.wasTruncated { Label("Diagnostic output was truncated.", systemImage: "scissors") }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(minHeight: 180)
                    } else { ContentUnavailableView("Select a Task", systemImage: "sidebar.right").frame(minHeight: 180) }
                }
            }
            if copyFailed { Label("Diagnostics could not be copied. Try again.", systemImage: "exclamationmark.circle") }
            HStack {
                Button("Copy Diagnostics", systemImage: "doc.on.doc") {
                    guard let record = store.records.first(where: { $0.id == selection }) else { return }
                    copyFailed = !clipboard.write(record.copyText(locale: locale))
                }.disabled(selection == nil)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(minWidth: 540, idealWidth: 680, minHeight: 440, idealHeight: 560)
        .onAppear { selection = store.records.contains { $0.id == initialSelection } ? initialSelection : nil }
        .onChange(of: store.records.map(\.id)) { _, ids in if let selection, !ids.contains(selection) { self.selection = nil } }
    }

    @ViewBuilder private func diagnosticSection(_ title: LocalizedStringResource, text: String) -> some View {
        if !text.isEmpty {
            GroupBox { Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                label: { Text(title) }
        }
    }
}
