import Foundation

enum UpdatesContentState: Equatable {
    case notLoaded, loading, available, failed, empty, noMatches

    init(states: [HomePackageUpdateState], totalCount: Int, visibleCount: Int) {
        if visibleCount > 0 { self = .available }
        else if states.contains(.loading) { self = .loading }
        else if states.contains(.failed) { self = .failed }
        else if states.contains(.notLoaded) { self = .notLoaded }
        else if totalCount > 0 { self = .noMatches }
        else { self = .empty }
    }
}

enum UpdatesCatalog {
    static func cards(homebrew: HomebrewSnapshot?, node: NodeSnapshot?, homebrewUpdates: HomePackageUpdateState,
                      nodeUpdates: HomePackageUpdateState, activeIntents: [BatchIntent] = [], runningItem: BatchItem? = nil,
                      stage: ActivityTaskStage? = nil) -> [CatalogCardState] {
        let activeItems = activeIntents.flatMap(\.items)
        let activeIndexes = Dictionary(uniqueKeysWithValues: activeItems.enumerated().map { ($0.element, $0.offset) })
        let runningIndex = runningItem.flatMap { activeIndexes[$0] }
        let installedPackages = Dictionary(uniqueKeysWithValues: (homebrew?.packages ?? []).map { ($0.identity, $0) })
        func progress(_ item: BatchItem) -> CatalogCardProgress {
            guard let index = activeIndexes[item] else { return .idle }
            if stage == .reconciling { return .verifying }
            if item == runningItem { return .running }
            guard let runningIndex else { return .queued }
            return index > runningIndex ? .queued : .idle
        }
        let brew = (homebrew?.outdatedPackages ?? []).compactMap { outdated in
            let package = installedPackages[outdated.identity]
            let available = outdated.currentVersion
            // Homebrew's typed outdated response can compare its own non-semver versions.
            let installed = outdated.installedVersions.joined(separator: ", ")
            let status: SemanticVersionStatus = homebrewUpdates == .available && homebrew?.sectionErrors[.outdated] == nil
                && !installed.isEmpty && available?.isEmpty == false ? .behind : .unknown
            return CatalogCardState(identity: .homebrew(outdated.identity), displayName: package?.displayName ?? outdated.identity.name,
                                    description: package?.description, currentVersion: installed.isEmpty ? nil : installed,
                                    availableVersion: available, versionStatus: status, websiteURL: package?.homepage.flatMap(URL.init(string:)),
                                    progress: progress(.homebrew(outdated.identity)), primaryAction: status.allowsUpdate ? .update : nil)
        }
        let npm: [CatalogCardState]
        if let node {
            let environment = LibraryCatalog.context(node.summary)
            npm = node.packages.compactMap { package in
                guard let available = package.latestVersion else { return nil }
                let knownStatus = SemanticVersionStatus(current: package.installedVersion, available: available)
                guard knownStatus != .current || nodeUpdates != .available || node.outdatedError != nil else { return nil }
                let status: SemanticVersionStatus = nodeUpdates == .available && node.outdatedError == nil ? knownStatus : .unknown
                let identity = NPMPackageIdentity(name: package.name, environment: environment)
                return CatalogCardState(identity: .npm(identity), displayName: package.name, description: nil,
                                        currentVersion: package.installedVersion, availableVersion: available,
                                        versionStatus: status, websiteURL: nil, progress: progress(.npm(identity)),
                                        primaryAction: status.allowsUpdate ? .update : nil)
            }
        } else { npm = [] }
        return (brew + npm).sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.identity.providerScope.rawValue < $1.identity.providerScope.rawValue : order == .orderedAscending
        }
    }

    static func visible(_ cards: [CatalogCardState], scope: CatalogScope, subtype: LibraryHomebrewSubtype) -> [CatalogCardState] {
        LibraryCatalog.filtered(cards, scope: scope, subtype: subtype, query: "")
    }

    static func intents(for visible: [CatalogCardState]) -> [BatchIntent] {
        let items = visible.filter { $0.versionStatus == .behind && $0.primaryAction == .update }.map(\.batchItem)
        var scopes: [BatchScope] = []
        for item in items where !scopes.contains(item.scope) { scopes.append(item.scope) }
        // Keep the established 100-item typed boundary without dropping visible targets.
        return scopes.flatMap { scope in
            let group = items.filter { $0.scope == scope }
            return stride(from: 0, to: group.count, by: 100).map { start in
                guard let intent = BatchIntent(operation: .update, items: Array(group[start..<min(start + 100, group.count)])) else {
                    preconditionFailure("Update cards retain unique typed identities")
                }
                return intent
            }
        }.sorted { left, right in
            func order(_ scope: BatchScope) -> Int {
                switch scope { case .homebrew(.formula): 0; case .homebrew(.cask): 1; case .npm: 2; case .nodeRuntime: 3 }
            }
            return order(left.scope) < order(right.scope)
        }
    }
}

struct UpdatesConfirmation: Identifiable, Sendable {
    let plan: BatchUpdatePlan
    let scope: CatalogScope
    let subtype: LibraryHomebrewSubtype
    var id: UUID { plan.id }
}

enum PackageUpdateError: Error, Equatable { case unavailable, staleContext }
