import AppKit
import SwiftUI

struct LoggingSettingsView: View {
    @ObservedObject var store: FileLogStore
    @State private var openFailed = false

    var body: some View {
        SettingsSection(title: "Logging") {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Log Level")
                    Text("Only the selected level and higher are saved. Changes apply immediately.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Picker("Log Level", selection: $store.minimumLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { level in Text(level.title).tag(level) }
                }.labelsHidden().buttonSizing(.flexible).frame(width: 180)
            }.frame(minHeight: AppLayout.minimumDescribedRowHeight)
            Divider()
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Keep Logs")
                    Text("Older logs are removed automatically. Each file is limited to 10 MB; total storage is limited to 50 MB.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Picker("Keep Logs", selection: $store.retention) {
                    ForEach(LogRetention.allCases, id: \.self) { retention in Text(retention.title).tag(retention) }
                }.labelsHidden().buttonSizing(.flexible).frame(width: 180)
            }.frame(minHeight: AppLayout.minimumDescribedRowHeight)
            Divider()
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Log Folder")
                    Text(store.directory.path(percentEncoded: false))
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Logs contain redacted task summaries. Raw terminal output stays in session diagnostics.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Open Log Folder", systemImage: "folder") {
                    Task {
                        store.retry()
                        await store.flush()
                        openFailed = !NSWorkspace.shared.open(store.directory)
                    }
                }
                .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large)
                .fixedSize()
            }.frame(minHeight: AppLayout.minimumDescribedRowHeight)
            if let error = store.errorMessage {
                Divider()
                Label("Logs could not be saved. Check available storage and folder permissions, then retry.", systemImage: "exclamationmark.triangle")
                Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Retry Saving Logs") { store.retry() }
                    .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if openFailed {
                Label("The log folder could not be opened. Check folder access and try again.", systemImage: "exclamationmark.triangle")
            }
        }
    }
}
