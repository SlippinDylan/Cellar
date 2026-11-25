import Foundation

extension NodeSummary {
    var activityEnvironment: NodeEnvironmentContext? {
        // An installed nvm without a resolved Node is a real state, not an empty environment.
        guard !nodePath.isEmpty, !npmPath.isEmpty else { return nil }
        return LibraryCatalog.context(self)
    }
}

struct ActivityRenderer {
    var locale: Locale = .current

    func localized(_ resource: LocalizedStringResource) -> String {
        var resource = resource
        resource.locale = locale
        return String(localized: resource)
    }

    func operation(_ operation: ActivityOperationKind) -> String {
        localized(operation.title)
    }

    func scope(_ scope: ActivityScope?) -> String {
        switch scope {
        case .homebrew(.formula): localized("Homebrew · Formula")
        case .homebrew(.cask): localized("Homebrew · Cask")
        case .homebrewTaps: localized("Homebrew · Taps")
        case .homebrewMetadata: localized("Homebrew · Metadata")
        case .homebrewDiagnostics: localized("Homebrew · Diagnostics")
        case .npm(let environment): localized("npm · Node \(environment.nodeVersion) · npm \(environment.npmVersion)")
        case .nodeRuntime(let environment): localized("Node Runtime · Node \(environment.nodeVersion)")
        case .shell: localized("Terminal")
        case nil: localized("Environment")
        }
    }

    func status(_ status: ActivityStatus) -> String { localized(status.title) }
    func itemStatus(_ status: BatchItemStatus) -> String { localized(status.activityTitle) }
    func reason(_ reason: ActivityItemReason) -> String { localized(reason.message) }
    func target(_ summary: ActivitySummary) -> String {
        if summary.scope == .shell { return summary.itemOutcomes.compactMap(\.shellStep).map { localized($0.title) }.joined(separator: ", ") }
        return targets(summary.targetDisplayNames, scope: summary.scope)
    }

    func targets(_ names: [String], scope: ActivityScope?) -> String {
        switch scope {
        case .homebrewMetadata: localized("Homebrew and Tap Metadata")
        case .homebrewDiagnostics: localized("Homebrew Health")
        default: names.joined(separator: ", ")
        }
    }

    func counts(_ summary: ActivitySummary) -> String {
        let groups = Dictionary(grouping: summary.itemOutcomes, by: \.status)
        return BatchItemStatus.allCases.compactMap { status in
            guard let items = groups[status] else { return nil }
            return "\(itemStatus(status)): \(items.count.formatted(.number.locale(locale)))"
        }.joined(separator: " · ")
    }

    func detail(_ summary: ActivitySummary) -> String {
        var lines = [operation(summary.operation),
                     summary.date.formatted(.dateTime.year().month().day().hour().minute().second().locale(locale)),
                     scope(summary.scope), status(summary.status)]
        let targets = target(summary)
        if !targets.isEmpty { lines.append(targets) }
        if let reason = summary.reason { lines.append(self.reason(reason)) }
        if !summary.itemOutcomes.isEmpty { lines.append(counts(summary)) }
        for item in summary.itemOutcomes {
            let name = item.shellStep.map { localized($0.title) } ?? item.displayName
            lines.append("\(name): \(itemStatus(item.status))")
            if let reason = item.reason { lines.append(self.reason(reason)) }
        }
        return lines.joined(separator: "\n")
    }
}

extension ActivityOperationKind {
    var title: LocalizedStringResource {
        switch self {
        case .refresh: LocalizedStringResource("Refresh Environment")
        case .search: LocalizedStringResource("Search Software")
        case .install: LocalizedStringResource("Install")
        case .update: LocalizedStringResource("Update")
        case .uninstall: LocalizedStringResource("Uninstall")
        case .setup: LocalizedStringResource("Environment Setup")
        case .requestCommandLineTools: LocalizedStringResource("Request Command Line Tools Installation")
        case .openHomebrewInstaller: LocalizedStringResource("Open Verified Homebrew Installer")
        case .configuration: LocalizedStringResource("Change Configuration")
        case .maintenance: LocalizedStringResource("Environment Maintenance")
        case .addHomebrewTap: LocalizedStringResource("Add Homebrew Tap")
        case .removeHomebrewTap: LocalizedStringResource("Remove Homebrew Tap")
        case .updateHomebrewMetadata: LocalizedStringResource("Update Homebrew Metadata")
        }
    }
}

extension ActivityStatus {
    var title: LocalizedStringResource {
        switch self {
        case .running: LocalizedStringResource("Running")
        case .succeeded: LocalizedStringResource("Succeeded")
        case .partiallySucceeded: LocalizedStringResource("Partially Completed")
        case .failed: LocalizedStringResource("Failed")
        case .cancelled: LocalizedStringResource("Cancelled")
        case .unknown: LocalizedStringResource("Result Unknown")
        }
    }
    var systemImage: String {
        switch self {
        case .running: "clock"
        case .succeeded: "checkmark.circle"
        case .partiallySucceeded: "exclamationmark.circle"
        case .failed: "xmark.circle"
        case .cancelled: "stop.circle"
        case .unknown: "questionmark.circle"
        }
    }
}

extension BatchItemStatus {
    var activityTitle: LocalizedStringResource {
        switch self {
        case .skipped: LocalizedStringResource("Skipped")
        case .succeeded: LocalizedStringResource("Succeeded")
        case .partiallySucceeded: LocalizedStringResource("Partially Completed")
        case .failed: LocalizedStringResource("Failed")
        case .cancelled: LocalizedStringResource("Cancelled")
        case .unknown: LocalizedStringResource("Result Unknown")
        }
    }
    var systemImage: String {
        switch self {
        case .skipped: "arrow.right.circle"
        case .succeeded: "checkmark.circle"
        case .partiallySucceeded: "exclamationmark.circle"
        case .failed: "xmark.circle"
        case .cancelled: "stop.circle"
        case .unknown: "questionmark.circle"
        }
    }
}

extension ActivityItemReason {
    static func verificationStatus(code: String) -> BatchItemStatus? {
        switch code {
        case "post-install-state-unavailable", "post-uninstall-state-unavailable", "update-verification-unavailable", "update-result-unavailable", "project-verification-unavailable": .unknown
        case "latest-verification-unavailable": .partiallySucceeded
        default: nil
        }
    }

    var message: LocalizedStringResource {
        switch self {
        case .stateChanged: LocalizedStringResource("The environment changed after confirmation. Refresh and review the task again.")
        case .unavailable: LocalizedStringResource("The target or required tool is unavailable. Refresh and check the environment.")
        case .timedOut: LocalizedStringResource("The task exceeded its time limit. Refresh to check the current state before trying again.")
        case .network: LocalizedStringResource("The service could not be reached. Check the connection and try again.")
        case .permission: LocalizedStringResource("The task could not access the required files. Check permissions and try again.")
        case .preparationFailed: LocalizedStringResource("The task could not be prepared safely. Refresh and review the selected targets.")
        case .providerFailure: LocalizedStringResource("The provider could not complete the task. Refresh to check the result before trying again.")
        case .cancelledByUser: LocalizedStringResource("The task was cancelled. Completed changes are retained. Refresh to check the current state.")
        case .stateUnavailable: LocalizedStringResource("The result could not be verified. Refresh to check the current state before trying again.")
        case .alreadySatisfied: LocalizedStringResource("The confirmed target version is already installed. No changes were needed.")
        case .alreadyInstalled: LocalizedStringResource("The package is already installed. Refresh Library to check its current version.")
        case .residueDetected: LocalizedStringResource("The package was removed, but some files remain. Review the uninstall results.")
        case .applicationRunning: LocalizedStringResource("The application is still running. Quit it before continuing.")
        case .authorizationFailed: LocalizedStringResource("Administrator cleanup did not finish. Check authorization and file permissions.")
        case .scanIncomplete: LocalizedStringResource("File ownership could not be fully verified. These files were kept.")
        }
    }
}

extension ActivityTaskStage {
    var title: LocalizedStringResource {
        switch self {
        case .preparing: LocalizedStringResource("Preparing Task")
        case .executing: LocalizedStringResource("Running")
        case .checking: LocalizedStringResource("Checking Environment")
        case .reconciling: LocalizedStringResource("Verifying Changes")
        }
    }
}
