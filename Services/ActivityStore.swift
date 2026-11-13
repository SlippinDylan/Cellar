import Combine
import Foundation

enum ActivityStoreError: Error, Equatable {
    case invalidSummary
}

@MainActor
final class ActivityStore: ObservableObject {
    @Published private(set) var summaries: [ActivitySummary] = []
    @Published private(set) var latestResults: [ActivitySummary] = []
    var latestResult: ActivitySummary? { latestResults.last }
    private var resultTaskID: UUID?
    @Published private(set) var verificationWarning: ActivityItemReason?
    @Published private(set) var validationError: ActivityStoreError?
    private let logStore: FileLogStore?
    private let operationStore: OperationStore?

    init(logStore: FileLogStore? = nil, operationStore: OperationStore? = nil) {
        self.logStore = logStore
        self.operationStore = operationStore
    }

    func append(_ summary: ActivitySummary) {
        do {
            try record(summary)
            validationError = nil
        } catch {
            validationError = error
            logStore?.record(level: .error, category: "tasks", message: "Task result rejected: invalid summary", taskID: summary.id)
        }
    }

    func record(_ summary: ActivitySummary) throws(ActivityStoreError) {
        let sanitized = try ActivitySummarySanitizer.sanitize(summary)
        summaries = Array(([sanitized] + summaries.filter { $0.id != sanitized.id }).prefix(100))
        // Read-only queries must not replace the operation result the user still needs to review.
        if sanitized.operation.showsTaskFeedback {
            let currentTaskID = operationStore?.currentOperation?.id
            if let currentTaskID, resultTaskID == currentTaskID {
                latestResults.removeAll { $0.id == sanitized.id }
                latestResults.append(sanitized)
            } else {
                latestResults = [sanitized]
            }
            resultTaskID = currentTaskID
            verificationWarning = nil
        } else if sanitized.operation == .refresh, sanitized.scope != nil, sanitized.status != .succeeded, latestResult != nil {
            verificationWarning = sanitized.reason ?? .stateUnavailable
        }
        let taskID = operationStore?.currentOperation?.id ?? sanitized.id
        let context = "result=\(sanitized.id.uuidString) operation=\(sanitized.operation.rawValue) scope=\(Self.logScope(sanitized.scope))"
        logStore?.record(level: Self.logLevel(sanitized.status), category: "tasks",
                         message: "Completed \(context) status=\(sanitized.status.rawValue) targets=\(sanitized.targetDisplayNames.joined(separator: ",")) reason=\(sanitized.reason?.rawValue ?? "none")",
                         taskID: taskID)
        for (index, item) in (sanitized.cleanupItems ?? []).enumerated() {
            logStore?.record(level: Self.logLevel(item.batchItemStatus.activityStatus), category: "tasks",
                             message: "Cleanup item \(context) index=\(index + 1) status=\(item.status.rawValue) reason=\(item.reason.rawValue)", taskID: taskID)
        }
        for item in sanitized.itemOutcomes {
            logStore?.record(level: Self.logLevel(item.status.activityStatus), category: "tasks",
                             message: "Item \(context) target=\(item.shellStep?.rawValue ?? item.displayName) status=\(item.status.rawValue) reason=\(item.reason?.rawValue ?? "none")",
                             taskID: taskID)
        }
    }

    func dismissResult() {
        latestResults = []
        resultTaskID = nil
        verificationWarning = nil
    }

    private static func logLevel(_ status: ActivityStatus) -> LogLevel {
        switch status {
        case .running, .succeeded: .info
        case .partiallySucceeded, .cancelled, .unknown: .warning
        case .failed: .error
        }
    }

    private static func logScope(_ scope: ActivityScope?) -> String {
        switch scope {
        case .homebrew(let kind): "homebrew.\(kind.rawValue)"
        case .homebrewTaps: "homebrew.taps"
        case .homebrewMetadata: "homebrew.metadata"
        case .homebrewDiagnostics: "homebrew.diagnostics"
        case .npm(let environment): "npm(node=\(environment.nodeVersion),npm=\(environment.npmVersion))"
        case .nodeRuntime(let environment): "node(\(environment.nodeVersion))"
        case .shell: "terminal"
        case nil: "environment"
        }
    }
}

enum ActivitySummarySanitizer {
    static func sanitize(_ summary: ActivitySummary) throws(ActivityStoreError) -> ActivitySummary {
        guard summary.status != .running, summary.targetDisplayNames.count <= 100, summary.itemOutcomes.count <= 100 else { throw .invalidSummary }
        if let items = summary.cleanupItems {
            guard summary.operation == .maintenance, items.count <= 1000, items.allSatisfy(\.hasValidEvidence),
                  Set(items.map(\.path)).count == items.count else { throw .invalidSummary }
        }
        if summary.scope == .shell {
            guard summary.date.timeIntervalSince1970.isFinite, summary.targetDisplayNames.isEmpty,
                  summary.itemOutcomes.allSatisfy({ $0.displayName.isEmpty && $0.shellStep != nil }),
                  Set(summary.itemOutcomes.compactMap(\.shellStep)).count == summary.itemOutcomes.count else { throw .invalidSummary }
            return summary
        }
        guard summary.date.timeIntervalSince1970.isFinite,
              summary.targetDisplayNames.allSatisfy({ validPackageIdentifier($0, scope: summary.scope) }),
              summary.itemOutcomes.allSatisfy({ $0.shellStep == nil && validPackageIdentifier($0.displayName, scope: summary.scope) })
        else { throw .invalidSummary }
        let scope: ActivityScope?
        switch summary.scope {
        case .npm(let environment), .nodeRuntime(let environment):
            guard validVersion(environment.nodeVersion), validVersion(environment.npmVersion) else { throw .invalidSummary }
            // Keep versions as semantic context; identifiers may contain private installation paths.
            let sanitizedEnvironment = NodeEnvironmentContext(
                identifier: "nvm:\(environment.nodeVersion)",
                nodeVersion: environment.nodeVersion,
                npmVersion: environment.npmVersion
            )
            if case .nodeRuntime = summary.scope { scope = .nodeRuntime(sanitizedEnvironment) }
            else { scope = .npm(sanitizedEnvironment) }
        case .homebrew, .homebrewTaps, .homebrewMetadata, .homebrewDiagnostics, .shell, nil:
            scope = summary.scope
        }
        return ActivitySummary(id: summary.id, operation: summary.operation, scope: scope,
                               targetDisplayNames: summary.targetDisplayNames, date: summary.date,
                               status: summary.status, itemOutcomes: summary.itemOutcomes, cleanupItems: summary.cleanupItems, reason: summary.reason)
    }

    private static func validVersion(_ version: String) -> Bool {
        let normalized = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let pieces = normalized.split(separator: ".", omittingEmptySubsequences: false)
        return normalized.count <= 64 && pieces.count == 3
            && pieces.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }
    }

    private static func validPackageIdentifier(_ name: String, scope: ActivityScope?) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 214 else { return false }
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        switch scope {
        case .homebrewTaps:
            return validHomebrewTap(name)
        case .homebrewMetadata, .homebrewDiagnostics:
            return false
        case .nodeRuntime:
            return validVersion(name)
        case .npm:
            return DiscoverBatchInput.validNPMSpec(name)
        case .homebrew:
            guard !name.hasPrefix("@"), components.count == 1 || components.count == 3 else { return false }
        case .shell, nil:
            return false
        }
        for (index, component) in components.enumerated() {
            let value = index == 0 && component.hasPrefix("@") ? component.dropFirst() : component[...]
            let versionParts = value.split(separator: "@", omittingEmptySubsequences: false)
            guard versionParts.count <= 2, let namePart = versionParts.first,
                  !namePart.isEmpty, namePart != ".", namePart != "..",
                  namePart.utf8.first.map({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) == true,
                  namePart.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95, 43].contains($0) })
            else { return false }
            if versionParts.count == 2 {
                let version = versionParts[1].split(separator: ".", omittingEmptySubsequences: false)
                guard (1...3).contains(version.count),
                      version.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } })
                else { return false }
            }
        }
        return true
    }

    static func validHomebrewTap(_ name: String) -> Bool {
        guard name.utf8.count <= 214, !name.hasPrefix("-") else { return false }
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        return components.count == 2 && components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
                && component.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [43, 45, 46, 95].contains($0) }
        }
    }
}
