import Foundation

struct DiscoverNPMContext: Equatable, Sendable {
    let environment: NodeEnvironmentContext
    let registryURL: URL
}

struct DiscoverContext: Equatable, Sendable {
    let homebrewAvailable: Bool
    let npm: DiscoverNPMContext?
    let nodeAvailable: Bool

    init(homebrewAvailable: Bool, npm: DiscoverNPMContext?, nodeAvailable: Bool = false) {
        self.homebrewAvailable = homebrewAvailable
        self.npm = npm
        self.nodeAvailable = nodeAvailable
    }
}

enum DiscoverSearchState: Equatable {
    case idle, loading, available, empty, failed, cancelled, busy
    case homebrewRequired, nodeRequired, registryRequired
}

enum DiscoverResult: Sendable {
    case homebrew(HomebrewPackage)
    case npm(NPMCatalogResult)

    var identity: CatalogItemIdentity {
        switch self {
        case .homebrew(let package): .homebrew(package.identity)
        case .npm(let package): .npm(package.identity)
        }
    }

    func card(homebrew: HomebrewSnapshot?, node: NodeSnapshot?, activeIntent: BatchIntent?, running: BatchItem?,
              canInstall: Bool, stage: ActivityTaskStage? = nil) -> CatalogCardState {
        let name: String
        let description: String?
        let available: String?
        let installed: String?
        let website: URL?
        let item: BatchItem
        switch self {
        case .homebrew(let package):
            name = package.displayName
            description = package.description
            available = package.currentVersion
            let current = homebrew?.packages.first { $0.identity == package.identity } ?? package
            installed = current.isInstalled ? current.installedVersions.joined(separator: ", ") : nil
            let component = package.identity.kind == .formula ? "formula" : "cask"
            website = CatalogWebsites.url(host: "formulae.brew.sh", path: "/\(component)/\(package.identity.name)")
            item = .homebrew(package.identity)
        case .npm(let package):
            name = package.identity.name
            description = package.description
            available = package.version
            if let node, LibraryCatalog.context(node.summary) == package.identity.environment {
                installed = node.packages.first { $0.name == name }?.installedVersion
            } else { installed = nil }
            website = package.websiteURL
            item = .npm(package.identity)
        }
        let status = SemanticVersionStatus(current: installed, available: available)
        // Discover installs missing software; Updates owns upgrading installed packages.
        guard let card = CatalogCardState(identity: identity, displayName: name, description: description,
                                           currentVersion: installed, availableVersion: available, versionStatus: status,
                                           websiteURL: website, progress: LibraryCatalog.progress(for: item, intent: activeIntent, running: running, stage: stage),
                                           primaryAction: installed == nil && canInstall ? .install : nil)
        else { preconditionFailure("An install card has no update invariant") }
        return card
    }
}

enum DiscoverInputError: Error, Equatable {
    case empty, tooMany, invalidTarget, missingContext, staleContext, sourceMismatch, mixedRegistries, installationFailed
}

enum DiscoverBatchInput {
    static func intent(_ input: String, scope: CatalogProviderScope, npm: DiscoverNPMContext?) throws -> BatchIntent {
        var seen = Set<String>()
        let names = input.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !names.isEmpty else { throw DiscoverInputError.empty }
        guard names.count <= 100 else { throw DiscoverInputError.tooMany }
        let items: [BatchItem]
        switch scope {
        case .homebrewFormula, .homebrewCask:
            guard names.allSatisfy(validHomebrewName) else { throw DiscoverInputError.invalidTarget }
            let kind: HomebrewPackageKind = scope == .homebrewFormula ? .formula : .cask
            items = names.map { .homebrew(.init(name: $0, kind: kind)) }
        case .npm:
            guard let npm else { throw DiscoverInputError.missingContext }
            guard names.allSatisfy(validNPMSpec) else { throw DiscoverInputError.invalidTarget }
            items = names.map { .npm(.init(name: $0, environment: npm.environment)) }
        }
        guard let intent = BatchIntent(operation: .install, items: items) else {
            preconditionFailure("Validated input must form one typed install intent")
        }
        return intent
    }

    static func validHomebrewName(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return name.utf8.count <= 214 && [1, 3].contains(parts.count) && parts.allSatisfy {
            $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9+._-]*(?:@[0-9]+(?:\.[0-9]+){0,2})?$"#, options: .regularExpression) != nil
        }
    }

    static func validNPMSpec(_ spec: String) -> Bool {
        guard spec.utf8.count <= 214, !spec.contains("..") else { return false }
        let parts = spec.dropFirst(spec.hasPrefix("@") ? 1 : 0).split(separator: "@", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return false }
        let name = (spec.hasPrefix("@") ? "@" : "") + parts[0]
        let components = name.dropFirst(name.hasPrefix("@") ? 1 : 0).split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == (name.hasPrefix("@") ? 2 : 1) else { return false }
        for (index, component) in components.enumerated() {
            let scoped = name.hasPrefix("@") && index == 0
            let pattern = scoped ? #"^[a-z0-9][a-z0-9._-]*$"# : #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#
            guard component != "node_modules", component != "favicon.ico", component.range(of: pattern, options: .regularExpression) != nil else { return false }
        }
        return parts.count == 1 || parts[1].range(of: #"^[A-Za-z0-9][A-Za-z0-9._~+-]*$"#, options: .regularExpression) != nil
    }
}

struct DiscoverInstallPreview: Identifiable {
    let plan: BatchPlan
    let context: DiscoverContext
    var id: UUID { plan.id }
    var intent: BatchIntent { plan.intent }
    var npm: DiscoverNPMContext? {
        plan.npmBindings.first.map { .init(environment: $0.environment, registryURL: $0.registryURL) }
    }
}
