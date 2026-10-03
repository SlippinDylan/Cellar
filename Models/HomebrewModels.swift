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
}

enum HomebrewCaskArtifactCategory: String, Sendable {
    case installed
    case zap
}

struct HomebrewCaskArtifact: Identifiable, Sendable {
    let kind: String
    let values: [String]
    let category: HomebrewCaskArtifactCategory

    var id: String { "\(category.rawValue):\(kind):\(values.joined(separator: "|"))" }
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
                snapshot.packages.contains { $0.identity == target && $0.isInstalled }
            }
        case .upgrade:
            let outdated = Set(snapshot.outdatedPackages.map(\.identity))
            return plan.targets.allSatisfy { !outdated.contains($0) }
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

    private func observationIsAvailable(in snapshot: HomebrewSnapshot) -> Bool {
        switch plan.action {
        case .install, .uninstallFormula, .uninstallCask, .zapCask:
            return snapshot.sectionErrors[.packages] == nil
        case .upgrade:
            return snapshot.sectionErrors[.outdated] == nil
        case .addTap, .removeTap:
            return snapshot.sectionErrors[.taps] == nil
        case .update:
            return true
        }
    }

    private func observedPartialChange(in snapshot: HomebrewSnapshot) -> Bool {
        let completedCount: Int
        switch plan.action {
        case .install:
            let installed = Set(snapshot.packages.filter(\.isInstalled).map(\.identity))
            completedCount = plan.targets.filter(installed.contains).count
        case .upgrade:
            let outdated = Set(snapshot.outdatedPackages.map(\.identity))
            completedCount = plan.targets.filter { !outdated.contains($0) }.count
        default:
            return false
        }
        return completedCount > 0 && completedCount < plan.targets.count
    }
}
