import Foundation

enum CatalogScope: String, Codable, CaseIterable, Sendable {
    case all
    case homebrew
    case npm
}

enum CatalogProviderScope: String, Codable, CaseIterable, Sendable {
    case homebrewFormula = "homebrew-formula"
    case homebrewCask = "homebrew-cask"
    case npm

    static func homebrew(_ kind: HomebrewPackageKind) -> Self {
        switch kind {
        case .formula: .homebrewFormula
        case .cask: .homebrewCask
        }
    }
}

struct NodeEnvironmentContext: Hashable, Codable, Sendable {
    let identifier: String
    let nodeVersion: String
    let npmVersion: String
}

struct NPMPackageIdentity: Hashable, Codable, Sendable {
    let name: String
    let environment: NodeEnvironmentContext
}

struct NodeRuntimeIdentity: Hashable, Codable, Sendable {
    let version: String
    let environment: NodeEnvironmentContext
}

enum CatalogItemIdentity: Hashable, Codable, Sendable {
    case homebrew(HomebrewPackageIdentity)
    case npm(NPMPackageIdentity)

    var providerScope: CatalogProviderScope {
        switch self {
        case .homebrew(let identity): .homebrew(identity.kind)
        case .npm: .npm
        }
    }

    var nodeEnvironment: NodeEnvironmentContext? {
        guard case .npm(let identity) = self else { return nil }
        return identity.environment
    }
}

enum CatalogCardProgress: String, Codable, Sendable {
    case idle
    case queued
    case running
    case verifying
}

enum CatalogCardAction: String, Codable, Sendable {
    case install
    case update
    case uninstall
}

struct CatalogCardState: Identifiable, Equatable, Sendable {
    let identity: CatalogItemIdentity
    let displayName: String
    let description: String?
    let currentVersion: String?
    let availableVersion: String?
    let versionStatus: SemanticVersionStatus
    let websiteURL: URL?
    let progress: CatalogCardProgress
    let primaryAction: CatalogCardAction?
    let icon: CatalogIcon

    init?(
        identity: CatalogItemIdentity,
        displayName: String,
        description: String?,
        currentVersion: String?,
        availableVersion: String?,
        versionStatus: SemanticVersionStatus,
        websiteURL: URL?,
        progress: CatalogCardProgress,
        primaryAction: CatalogCardAction?,
        icon: CatalogIcon = .placeholder
    ) {
        guard primaryAction != .update || versionStatus.allowsUpdate else { return nil }
        self.identity = identity
        self.displayName = displayName
        self.description = description
        self.currentVersion = currentVersion
        self.availableVersion = availableVersion
        self.versionStatus = versionStatus
        self.websiteURL = CatalogWebsites.safeWebsite(websiteURL)
        self.progress = progress
        self.primaryAction = primaryAction
        self.icon = icon
    }

    var id: CatalogItemIdentity { identity }
    var nodeEnvironment: NodeEnvironmentContext? { identity.nodeEnvironment }
}

struct HomebrewInstallation: Equatable, Sendable {
    let executablePath: String
    let version: String
}

enum HomebrewInstallationState: Equatable, Sendable {
    case notChecked
    case checking
    case commandLineToolsRequired
    case notInstalled
    case installed(HomebrewInstallation)
    case unavailable(reason: String)
}

enum OnlineVersionState: Equatable, Sendable {
    case notLoaded
    case loading
    case available(version: String)
    case unavailable(reason: String)
}

enum SemanticVersionStatus: String, Codable, Sendable {
    case behind
    case current
    case ahead
    case unknown

    init(current: String?, available: String?) {
        guard let current,
              let available,
              let currentVersion = ParsedSemanticVersion(current),
              let availableVersion = ParsedSemanticVersion(available)
        else {
            self = .unknown
            return
        }

        if currentVersion < availableVersion {
            self = .behind
        } else if currentVersion > availableVersion {
            self = .ahead
        } else {
            self = .current
        }
    }

    var allowsUpdate: Bool { self == .behind }
}

private struct ParsedSemanticVersion: Comparable {
    enum Identifier: Equatable {
        case numeric(Int)
        case text(String)
    }

    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [Identifier]

    init?(_ value: String) {
        let buildParts = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        if buildParts.count == 2 {
            guard Self.validIdentifiers(buildParts[1]) else { return nil }
        }

        let versionParts = buildParts[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let core = versionParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Self.number(core[0]),
              let minor = Self.number(core[1]),
              let patch = Self.number(core[2])
        else { return nil }

        var prerelease: [Identifier] = []
        if versionParts.count == 2 {
            let identifiers = versionParts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !identifiers.isEmpty else { return nil }
            for identifier in identifiers {
                guard Self.validIdentifier(identifier) else { return nil }
                if let number = Int(identifier) {
                    guard identifier == "0" || !identifier.hasPrefix("0") else { return nil }
                    prerelease.append(.numeric(number))
                } else {
                    prerelease.append(.text(String(identifier)))
                }
            }
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let lhsCore = (lhs.major, lhs.minor, lhs.patch)
        let rhsCore = (rhs.major, rhs.minor, rhs.patch)
        if lhsCore != rhsCore { return lhsCore < rhsCore }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }

        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (left, right) {
            case (.numeric(let left), .numeric(let right)): return left < right
            case (.numeric, .text): return true
            case (.text, .numeric): return false
            case (.text(let left), .text(let right)): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func number(_ value: Substring) -> Int? {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ (48...57).contains($0) }),
              value == "0" || !value.hasPrefix("0")
        else { return nil }
        return Int(value)
    }

    private static func validIdentifiers(_ value: Substring) -> Bool {
        let identifiers = value.split(separator: ".", omittingEmptySubsequences: false)
        return !identifiers.isEmpty && identifiers.allSatisfy(validIdentifier)
    }

    private static func validIdentifier(_ value: Substring) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            byte == 45
                || (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
        }
    }
}

struct NPMRegistrySearchResponse: Decodable, Sendable {
    let objects: [NPMRegistrySearchResult]
    let total: Int
}

struct NPMRegistrySearchResult: Decodable, Sendable {
    struct Package: Decodable, Sendable {
        struct Links: Decodable, Sendable {
            let npm: URL?
            let homepage: URL?
        }

        let name: String
        let version: String
        let description: String?
        let links: Links?
    }

    let package: Package
}

enum BatchOperation: String, Codable, Sendable {
    case install
    case update
    case uninstall
}

enum BatchItem: Hashable, Codable, Sendable {
    case homebrew(HomebrewPackageIdentity)
    case npm(NPMPackageIdentity)
    case nodeRuntime(NodeRuntimeIdentity)

    var scope: BatchScope {
        switch self {
        case .homebrew(let identity): .homebrew(identity.kind)
        case .npm(let identity): .npm(identity.environment)
        case .nodeRuntime(let identity): .nodeRuntime(identity.environment)
        }
    }

    var displayIdentifier: String {
        switch self {
        case .homebrew(let identity): identity.name
        case .npm(let identity): identity.name
        case .nodeRuntime(let identity): identity.version
        }
    }
}

enum BatchScope: Hashable, Codable, Sendable {
    case homebrew(HomebrewPackageKind)
    case npm(NodeEnvironmentContext)
    case nodeRuntime(NodeEnvironmentContext)
}

struct BatchIntent: Equatable, Sendable {
    let operation: BatchOperation
    let scope: BatchScope
    let items: [BatchItem]

    init?(operation: BatchOperation, items: [BatchItem]) {
        guard let scope = items.first?.scope,
              items.count <= 100,
              items.allSatisfy({ $0.scope == scope }),
              Set(items).count == items.count
        else { return nil }
        if operation == .uninstall, items.count != 1 { return nil }
        if case .nodeRuntime = scope, operation != .uninstall { return nil }
        self.operation = operation
        self.scope = scope
        self.items = items
    }
}

enum BatchItemStatus: String, Codable, CaseIterable, Sendable {
    case skipped
    case succeeded
    case partiallySucceeded
    case failed
    case cancelled
    case unknown

    var activityStatus: ActivityStatus {
        switch self {
        case .succeeded, .skipped: .succeeded
        case .partiallySucceeded: .partiallySucceeded
        case .failed: .failed
        case .cancelled: .cancelled
        case .unknown: .unknown
        }
    }
}

struct BatchItemOutcome: Equatable, Sendable {
    let item: BatchItem
    let status: BatchItemStatus
    let userFacingMessage: String?
    var reason: ActivityItemReason? = nil
}

enum ActivityStatus: String, Codable, CaseIterable, Sendable {
    case running
    case succeeded
    case partiallySucceeded
    case failed
    case cancelled
    case unknown

    var itemStatus: BatchItemStatus {
        switch self {
        case .succeeded: .succeeded
        case .failed: .failed
        case .cancelled: .cancelled
        case .partiallySucceeded: .partiallySucceeded
        case .running, .unknown: .unknown
        }
    }

    var itemReason: ActivityItemReason? {
        switch self {
        case .succeeded, .running: nil
        case .failed: .providerFailure
        case .cancelled: .cancelledByUser
        case .partiallySucceeded: .providerFailure
        case .unknown: .stateUnavailable
        }
    }
}

struct BatchOutcome: Equatable, Sendable {
    let intent: BatchIntent
    let itemOutcomes: [BatchItemOutcome]

    init?(intent: BatchIntent, itemOutcomes: [BatchItemOutcome]) {
        guard itemOutcomes.map(\.item) == intent.items else { return nil }
        self.intent = intent
        self.itemOutcomes = itemOutcomes
    }

    var status: ActivityStatus {
        let itemOutcomes = itemOutcomes.filter { $0.status != .skipped }
        if itemOutcomes.allSatisfy({ $0.status == .succeeded }) { return .succeeded }
        if itemOutcomes.contains(where: { $0.status == .succeeded || $0.status == .partiallySucceeded }) { return .partiallySucceeded }
        if itemOutcomes.allSatisfy({ $0.status == .cancelled }) { return .cancelled }
        if itemOutcomes.allSatisfy({ $0.status == .unknown }) { return .unknown }
        return .failed
    }

    var succeededItemCount: Int {
        itemOutcomes.count(where: { $0.status == .succeeded })
    }
}

enum ActivityOperationKind: String, Codable, CaseIterable, Sendable {
    case refresh
    case search
    case install
    case update
    case uninstall
    case setup
    case requestCommandLineTools
    case openHomebrewInstaller
    case configuration
    case maintenance
    case addHomebrewTap
    case removeHomebrewTap
    case updateHomebrewMetadata

    var showsTaskFeedback: Bool { self != .refresh && self != .search }
}

enum ActivityItemReason: String, Codable, CaseIterable, Sendable {
    case providerFailure
    case cancelledByUser
    case stateUnavailable
    case stateChanged
    case unavailable
    case network
    case timedOut
    case permission
    case preparationFailed
    case alreadyInstalled
    case alreadySatisfied
    case residueDetected
    case applicationRunning
    case authorizationFailed
    case scanIncomplete
}

struct ActivityItemSummary: Equatable, Codable, Sendable {
    let displayName: String
    let status: BatchItemStatus
    let reason: ActivityItemReason?
    var shellStep: ShellActivityStep? = nil
}

enum ActivityScope: Hashable, Codable, Sendable {
    case homebrew(HomebrewPackageKind)
    case homebrewTaps
    case homebrewMetadata
    case homebrewDiagnostics
    case npm(NodeEnvironmentContext)
    case nodeRuntime(NodeEnvironmentContext)
    case shell
}

struct ActivitySummary: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let operation: ActivityOperationKind
    let scope: ActivityScope?
    let targetDisplayNames: [String]
    let date: Date
    let status: ActivityStatus
    let itemOutcomes: [ActivityItemSummary]
    var cleanupItems: [NodeCleanupItem]? = nil
    var reason: ActivityItemReason? = nil
}

enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case followSystem = "system"
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case german = "de"
    case french = "fr"
    case spanish = "es"

    var localeIdentifier: String? {
        self == .followSystem ? nil : rawValue
    }

    var locale: Locale? {
        localeIdentifier.map(Locale.init(identifier:))
    }
}
