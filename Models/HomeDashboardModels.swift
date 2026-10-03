import Foundation

enum HomeOnlineSource: String, CaseIterable, Sendable {
    case homebrew, node, npm, nvm
}

enum HomePackageUpdateState: Equatable, Sendable {
    case notLoaded, loading, available, failed
}

enum HomeCommandLineToolsState: Equatable, Sendable {
    case notLoaded
    case loading
    case available(CommandLineToolsState)
    case failed
}

enum HomeSetupFailure: Equatable, Sendable {
    case commandLineTools
    case homebrew(HomebrewSetupFailure)
}

enum HomeSetupState: Equatable, Sendable {
    case idle
    case requestingCommandLineTools
    case commandLineToolsRequested
    case preparingInstaller
    case installerOpened
    case failed(HomeSetupFailure)
}

struct HomeUpdatePreview: Equatable, Sendable {
    let names: [String]
    let totalCount: Int
    var remainingCount: Int { totalCount - names.count }

    init(names: [String]) {
        self.names = Array(names.sorted().prefix(5))
        totalCount = names.count
    }
}

struct HomebrewDashboardSummary: Sendable {
    let version: String
    let formulaCount: Int?
    let caskCount: Int?
    let updates: HomeUpdatePreview?
    let hasPartialFailure: Bool

    init(snapshot: HomebrewSnapshot) {
        version = HomeVersion.normalized(snapshot.version)
        let inventoryAvailable = snapshot.sectionErrors[.packages] == nil
        formulaCount = inventoryAvailable ? snapshot.packages.count { $0.isInstalled && $0.identity.kind == .formula } : nil
        caskCount = inventoryAvailable ? snapshot.packages.count { $0.isInstalled && $0.identity.kind == .cask } : nil
        updates = snapshot.sectionErrors[.outdated] == nil ? HomeUpdatePreview(names: snapshot.outdatedPackages.map(\.identity.name)) : nil
        hasPartialFailure = snapshot.sectionErrors.keys.contains { $0 != .outdated }
    }
}

struct NodeDashboardSummary: Sendable {
    let nodeVersion: String
    let npmVersion: String
    let defaultVersion: String?
    let packageCount: Int
    let updates: HomeUpdatePreview?

    init(snapshot: NodeSnapshot) {
        nodeVersion = snapshot.summary.nodeVersion
        npmVersion = snapshot.summary.npmVersion
        defaultVersion = snapshot.installations.first(where: \.isDefault)?.version
        packageCount = snapshot.packages.count
        updates = snapshot.outdatedError == nil
            ? HomeUpdatePreview(names: snapshot.packages.filter {
                SemanticVersionStatus(current: $0.installedVersion, available: $0.latestVersion).allowsUpdate
            }.map(\.name)) : nil
    }
}

enum HomeVersion {
    static func normalized(_ version: String) -> String {
        let value = version.hasPrefix("Homebrew ") ? String(version.dropFirst(9)) : version
        return value.hasPrefix("v") ? String(value.dropFirst()) : value
    }
}
