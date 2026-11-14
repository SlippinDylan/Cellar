import Foundation

enum HomebrewPackageKind: String, Codable, CaseIterable, Sendable {
    case formula
    case cask

    var sortOrder: Int {
        switch self {
        case .formula: 0
        case .cask: 1
        }
    }
}

struct HomebrewPackageIdentity: Hashable, Codable, Sendable {
    let name: String
    let kind: HomebrewPackageKind
}

struct HomebrewPackage: Identifiable, Sendable {
    let identity: HomebrewPackageIdentity
    let displayName: String
    let description: String?
    let homepage: String?
    let installedVersions: [String]
    let currentVersion: String?
    let tap: String?
    let dependencies: [String]
    let pinned: Bool
    let deprecated: Bool
    let disabled: Bool
    let artifacts: [HomebrewCaskArtifact]
    var aliases: [String] = []
    var oldTokens: [String] = []
    var installedCaskToken: String? = nil

    var id: HomebrewPackageIdentity { identity }
    var isInstalled: Bool { !installedVersions.isEmpty }
}

struct HomebrewOutdatedPackage: Identifiable, Sendable {
    let identity: HomebrewPackageIdentity
    let installedVersions: [String]
    let currentVersion: String?

    var id: HomebrewPackageIdentity { identity }
}

struct HomebrewTap: Identifiable, Sendable {
    let name: String
    let remote: String?
    let path: String
    let official: Bool
    let trusted: Bool
    let formulaNames: [String]
    let caskTokens: [String]

    var id: String { name }
}

struct HomebrewConfiguration: Sendable {
    let prefix: String
    let repository: String
    let cache: String
    let cellar: String
    let values: [String: String]
}

enum HomebrewDiagnosticSeverity: String, Sendable {
    case info
    case warning
    case error
}

struct HomebrewDiagnostic: Identifiable, Sendable {
    let id: String
    let severity: HomebrewDiagnosticSeverity
    let message: String
}

struct HomebrewDiagnosticReport: Sendable {
    let diagnostics: [HomebrewDiagnostic]
    let command: HomebrewCommandOutput
}

struct HomebrewSearchResult: Identifiable, Sendable {
    let identity: HomebrewPackageIdentity

    var id: HomebrewPackageIdentity { identity }
}

struct HomebrewSnapshot: Sendable {
    enum Section: String, Hashable, Sendable {
        case configuration
        case packages
        case outdated
        case taps
    }

    let executablePath: String
    let version: String
    let configuration: HomebrewConfiguration
    let packages: [HomebrewPackage]
    let outdatedPackages: [HomebrewOutdatedPackage]
    let taps: [HomebrewTap]
    let sectionErrors: [Section: String]
    let controlledPath: String
    let commandLineToolsAvailable: Bool

    func replacingOutdated(packages: [HomebrewOutdatedPackage], error: String?) -> Self {
        var errors = sectionErrors
        errors[.outdated] = error
        return Self(executablePath: executablePath, version: version, configuration: configuration,
                    packages: self.packages, outdatedPackages: packages, taps: taps, sectionErrors: errors,
                    controlledPath: controlledPath, commandLineToolsAvailable: commandLineToolsAvailable)
    }

    func retainingFailedSections(from previous: Self?) -> Self {
        guard let previous, executablePath == previous.executablePath,
              sectionErrors[.configuration] != nil || previous.configuration.prefix.isEmpty
                || configuration.prefix == previous.configuration.prefix else { return self }
        let merged = Self(executablePath: executablePath, version: version,
                          configuration: sectionErrors[.configuration] == nil ? configuration : previous.configuration,
                          packages: sectionErrors[.packages] == nil ? packages : previous.packages,
                          outdatedPackages: outdatedPackages,
                          taps: sectionErrors[.taps] == nil ? taps : previous.taps,
                          sectionErrors: sectionErrors, controlledPath: controlledPath,
                          commandLineToolsAvailable: commandLineToolsAvailable)
        return merged.retainingKnownOutdated(from: previous)
    }

    func retainingKnownOutdated(from previous: Self?) -> Self {
        guard sectionErrors[.outdated] != nil, let previous,
              executablePath == previous.executablePath,
              previous.configuration.prefix.isEmpty || configuration.prefix == previous.configuration.prefix else { return self }
        let installed = Dictionary(uniqueKeysWithValues: packages.filter(\.isInstalled).map { ($0.identity, $0) })
        let retained = previous.outdatedPackages.compactMap { outdated -> HomebrewOutdatedPackage? in
            guard let package = installed[outdated.identity] else { return nil }
            return HomebrewOutdatedPackage(identity: outdated.identity, installedVersions: package.installedVersions, currentVersion: outdated.currentVersion)
        }
        return replacingOutdated(packages: retained, error: sectionErrors[.outdated])
    }
}

enum HomebrewCaskArtifactCategory: String, Sendable {
    case installed
    case zap
}

struct HomebrewCaskArtifact: Identifiable, Sendable {
    let kind: String
    let values: [String]
    let category: HomebrewCaskArtifactCategory
    var application: HomebrewCaskApplicationArtifact? = nil
    var uninstallDeletePaths: [String] = []

    var id: String { "\(category.rawValue):\(kind):\(values.joined(separator: "|")):\(application?.target ?? "")" }
}

struct HomebrewCaskApplicationArtifact: Sendable, Hashable {
    let source: String
    let target: String?
}

struct HomebrewResidualPath: Identifiable, Sendable {
    let path: String
    let artifactKind: String
    let estimatedBytes: Int64?

    var id: String { "\(artifactKind):\(path)" }
}

enum HomebrewAction: String, Sendable {
    case install
    case upgrade
    case update
    case addTap
    case removeTap
    case uninstallFormula
    case uninstallCask
    case zapCask
}

struct HomebrewConfirmedTarget: Equatable, Sendable {
    let identity: HomebrewPackageIdentity
    let source: String
    let version: String
    let prefix: String
}

struct HomebrewActionPlan: Identifiable, Sendable {
    let id: UUID
    let action: HomebrewAction
    let targets: [HomebrewPackageIdentity]
    let tapName: String?
    let dependencies: [String]
    let dependents: [String]
    let artifacts: [HomebrewCaskArtifact]
    let residualPaths: [HomebrewResidualPath]
    let associatedPackages: [HomebrewPackageIdentity]
    let generatedAt: Date
    let stateFingerprint: String?
    var confirmedTargets: [HomebrewConfirmedTarget] = []
    var caskRemoval: CaskRemovalPlan? = nil

    var canExecute: Bool {
        action != .removeTap || associatedPackages.isEmpty
    }
}

struct HomebrewCommandOutput: Sendable {
    let arguments: [String]
    let standardOutput: String
    let standardError: String
    let terminationStatus: Int32
    let standardOutputWasTruncated: Bool
    let standardErrorWasTruncated: Bool
}

struct HomebrewActionResult: Sendable {
    let plan: HomebrewActionPlan
    let command: HomebrewCommandOutput
    let snapshot: HomebrewSnapshot?
    let postflightError: String?
    let remainingResidualPaths: [HomebrewResidualPath]
    var caskRemovalFailures: [CaskRemovalFailure] = []
    var caskRemovalPathResults: [CaskRemovalPathResult] = []

    enum Outcome: Sendable, Equatable {
        case succeeded
        case partial
        case failed
        case stateUnknown
    }

    var outcome: Outcome {
        guard let snapshot else { return .stateUnknown }
        guard observationIsAvailable(in: snapshot) else { return .stateUnknown }
        if plan.action == .update {
            return command.terminationStatus == 0 ? .succeeded : .failed
        }
        let stateMatchesPlan = observedStateMatchesPlan(in: snapshot)
        if command.terminationStatus == 0, stateMatchesPlan {
            if let removal = plan.caskRemoval {
                let expected = Set(removal.entries.filter { $0.disposition != .protected }.map(\.path))
                if !caskRemovalFailures.isEmpty || remainingResidualPaths.contains(where: { expected.contains($0.path) }) {
                    return .partial
                }
            }
            return .succeeded
        }
        if stateMatchesPlan || observedPartialChange(in: snapshot) {
            return .partial
        }
        return .failed
    }

    var succeeded: Bool { outcome == .succeeded }

    private func observedStateMatchesPlan(in snapshot: HomebrewSnapshot) -> Bool {
        switch plan.action {
        case .install:
            return plan.targets.allSatisfy { target in
                targetIsSatisfied(target, in: snapshot)
            }
        case .upgrade:
            return plan.targets.allSatisfy { targetIsSatisfied($0, in: snapshot) }
        case .update:
            return true
        case .addTap:
            return plan.tapName.map { name in snapshot.taps.contains { $0.name == name } } ?? false
        case .removeTap:
            return plan.tapName.map { name in !snapshot.taps.contains { $0.name == name } } ?? false
        case .uninstallFormula, .uninstallCask, .zapCask:
            return plan.targets.allSatisfy { target in
                !snapshot.packages.contains { $0.identity == target && $0.isInstalled }
            }
        }
    }

    private func targetIsSatisfied(_ target: HomebrewPackageIdentity, in snapshot: HomebrewSnapshot) -> Bool {
        guard let package = snapshot.packages.first(where: { $0.identity == target }), package.isInstalled else { return false }
        guard let confirmed = plan.confirmedTargets.first(where: { $0.identity == target }) else { return false }
        return package.tap == confirmed.source && package.installedVersions.contains(confirmed.version)
            && snapshot.configuration.prefix == confirmed.prefix
    }

    private func observationIsAvailable(in snapshot: HomebrewSnapshot) -> Bool {
        switch plan.action {
        case .install, .upgrade:
            return snapshot.sectionErrors[.packages] == nil && snapshot.sectionErrors[.configuration] == nil
                && (plan.action != .upgrade || snapshot.sectionErrors[.outdated] == nil)
        case .uninstallFormula, .uninstallCask, .zapCask:
            return snapshot.sectionErrors[.packages] == nil
        case .addTap, .removeTap:
            return snapshot.sectionErrors[.taps] == nil
        case .update:
            return true
        }
    }

    private func observedPartialChange(in snapshot: HomebrewSnapshot) -> Bool {
        let completedCount: Int
        switch plan.action {
        case .install, .upgrade:
            completedCount = plan.targets.filter { targetIsSatisfied($0, in: snapshot) }.count
        default:
            return false
        }
        return completedCount > 0 && completedCount < plan.targets.count
    }
}

struct HomebrewDiscoveryResult: Sendable {
    let packages: [HomebrewPackage]
    let failedDetailCount: Int

    var isUnavailable: Bool { packages.isEmpty && failedDetailCount > 0 }
}
