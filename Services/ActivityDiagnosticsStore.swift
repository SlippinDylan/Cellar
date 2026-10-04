import AppKit
import Combine
import Foundation

struct ActivityDiagnosticRecord: Identifiable, Equatable, Sendable {
    static let textLimit = 16_000
    let id: UUID
    let date: Date
    let operation: ActivityOperationKind
    let scope: ActivityScope?
    let detail: String
    let command: String
    let standardOutput: String
    let standardError: String
    let wasTruncated: Bool

    func copyText(locale: Locale) -> String {
        let renderer = ActivityRenderer(locale: locale)
        var lines = [renderer.localized("Current Session Diagnostics"), renderer.localized("Diagnostics may contain sensitive information. Review before sharing; redaction cannot recognize every secret."),
                     renderer.operation(operation), renderer.scope(scope),
                     date.formatted(.dateTime.year().month().day().hour().minute().second().locale(locale))]
        for (title, text) in [(LocalizedStringResource("Technical Details"), detail), ("Command", command), ("Standard Output", standardOutput), ("Standard Error", standardError)] where !text.isEmpty {
            lines += [renderer.localized(title), text]
        }
        if wasTruncated { lines.append(renderer.localized("Diagnostic output was truncated.")) }
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class ActivityDiagnosticsStore: ObservableObject {
    @Published private(set) var records: [ActivityDiagnosticRecord] = []

    func record(id: UUID = UUID(), operation: ActivityOperationKind, scope: ActivityScope?, detail: String,
                command: HomebrewCommandOutput? = nil) {
        let values = [detail, command.map { "brew " + $0.arguments.joined(separator: " ") } ?? "", command?.standardOutput ?? "", command?.standardError ?? ""]
        let sanitized = values.map { String(DiagnosticText.sanitized(String($0.prefix(ActivityDiagnosticRecord.textLimit * 4))).prefix(ActivityDiagnosticRecord.textLimit)) }
        let record = ActivityDiagnosticRecord(id: id, date: Date(), operation: operation, scope: scope,
                                             detail: sanitized[0], command: sanitized[1], standardOutput: sanitized[2], standardError: sanitized[3],
                                             wasTruncated: values.contains { $0.count > ActivityDiagnosticRecord.textLimit }
                                                || command?.standardOutputWasTruncated == true || command?.standardErrorWasTruncated == true)
        records = Array(([record] + records.filter { $0.id != id }).prefix(100))
    }
}

@MainActor
struct ActivityClipboard {
    let write: (String) -> Bool
    static let live = ActivityClipboard { value in
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(value, forType: .string)
    }
    func copy(_ summary: ActivitySummary, locale: Locale) -> Bool {
        write(ActivityRenderer(locale: locale).detail(summary))
    }
}
