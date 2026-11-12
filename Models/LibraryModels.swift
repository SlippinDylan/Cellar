import Foundation

enum LibraryHomebrewSubtype: String, CaseIterable, Sendable {
    case all, formula, cask
}

enum LibraryUpdateFilter: String, CaseIterable {
    case all, pendingUpdates
}

enum LibraryReadState: Equatable {
    case loading, available, failed
}

enum LibraryContentState: Equatable {
    case loading, available, failed, empty, noMatches

    init(readStates: [LibraryReadState], totalCount: Int, matchCount: Int) {
        if matchCount > 0 { self = .available }
        else if totalCount > 0 { self = .noMatches }
        else if readStates.contains(.loading) { self = .loading }
        else if readStates.contains(.failed) { self = .failed }
        else { self = .empty }
    }
}

enum LibraryCatalog {
    static func cards(homebrew: HomebrewSnapshot?, node: NodeSnapshot?, homebrewUpdates: HomePackageUpdateState,
                      nodeUpdates: HomePackageUpdateState, activeIntents: [BatchIntent] = [], runningItem: BatchItem? = nil,
                      stage: ActivityTaskStage? = nil) -> [CatalogCardState] {
        let activeItems = activeIntents.flatMap(\.items)
        let outdated = Dictionary(uniqueKeysWithValues: (homebrew?.outdatedPackages ?? []).map { ($0.identity, $0) })
        let brewCards = (homebrew?.packages ?? []).filter(\.isInstalled).compactMap { package in
            let identity = CatalogItemIdentity.homebrew(package.identity)
            let available = outdated[package.identity]?.currentVersion ?? package.currentVersion
            let installed = package.installedVersions.joined(separator: ", ")
            let status: SemanticVersionStatus
            if homebrewUpdates != .available || homebrew?.sectionErrors[.outdated] != nil { status = .unknown }
            else if outdated[package.identity] != nil { status = .behind }
            else { status = SemanticVersionStatus(current: installed, available: available) }
            return CatalogCardState(identity: identity, displayName: package.displayName, description: package.description,
                                    currentVersion: installed, availableVersion: available, versionStatus: status,
                                    websiteURL: package.homepage.flatMap(URL.init(string:)),
                                    progress: progress(for: .homebrew(package.identity), items: activeItems, running: runningItem, stage: stage), primaryAction: .uninstall,
                                    icon: .homebrew(package))
        }
        let npmCards: [CatalogCardState]
        if let node {
            let environment = context(node.summary)
            npmCards = node.packages.compactMap { package in
                let identity = NPMPackageIdentity(name: package.name, environment: environment)
                let available = nodeUpdates == .available && node.outdatedError == nil ? package.latestVersion : nil
                return CatalogCardState(identity: .npm(identity), displayName: package.name, description: nil,
                                        currentVersion: package.installedVersion, availableVersion: available,
                                        versionStatus: SemanticVersionStatus(current: package.installedVersion, available: available),
                                        websiteURL: nil, progress: progress(for: .npm(identity), items: activeItems, running: runningItem, stage: stage), primaryAction: .uninstall)
            }
        } else { npmCards = [] }
        return (brewCards + npmCards).sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.identity.providerScope.rawValue < $1.identity.providerScope.rawValue : order == .orderedAscending
        }
    }

    static func filtered(_ cards: [CatalogCardState], scope: CatalogScope, subtype: LibraryHomebrewSubtype, query: String) -> [CatalogCardState] {
        contents(cards, scope: scope, subtype: subtype, query: query).matching
    }

    static func contents(_ cards: [CatalogCardState], scope: CatalogScope, subtype: LibraryHomebrewSubtype, query: String,
                         updateFilter: LibraryUpdateFilter = .all, updateCards: [CatalogCardState] = []) -> (scoped: [CatalogCardState], matching: [CatalogCardState]) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = Set(updateTargets(for: cards, from: updateCards).map(\.identity))
        return cards.reduce(into: (scoped: [], matching: [])) { result, card in
            let inScope: Bool = switch (scope, card.identity.providerScope) {
            case (.all, _), (.homebrew, .homebrewFormula), (.homebrew, .homebrewCask), (.npm, .npm): true
            default: false
            }
            let inSubtype = scope != .homebrew || subtype == .all
                || (subtype == .formula && card.identity.providerScope == .homebrewFormula)
                || (subtype == .cask && card.identity.providerScope == .homebrewCask)
            guard inScope && inSubtype, updateFilter == .all || pending.contains(card.identity) else { return }
            result.scoped.append(card)
            if matches(query, values: [card.displayName, card.description ?? "", card.batchItem.displayIdentifier]) {
                result.matching.append(card)
            }
        }
    }

    static func updateTargets(for cards: [CatalogCardState], from updates: [CatalogCardState]) -> [CatalogCardState] {
        let installed = Dictionary(uniqueKeysWithValues: cards.map { ($0.identity, $0) })
        // Preserve the canonical update card, including its captured version baseline and Node identity.
        return updates.filter { target in
            guard let card = installed[target.identity] else { return false }
            return target.primaryAction == .update && target.versionStatus == .behind
                && card.currentVersion == target.currentVersion
        }
    }

    static func matches(_ query: String, values: [String]) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || values.contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    static func context(_ summary: NodeSummary) -> NodeEnvironmentContext {
        // Executable identity distinguishes installations even when their versions match.
        .init(identifier: summary.nodePath, nodeVersion: summary.nodeVersion, npmVersion: summary.npmVersion)
    }

    static func uninstallIntent(_ item: BatchItem) -> BatchIntent? {
        let normalized: BatchItem = switch item {
        case .homebrew(let identity): .homebrew(.init(name: identity.name.trimmingCharacters(in: .whitespacesAndNewlines), kind: identity.kind))
        case .npm(let identity): .npm(.init(name: identity.name.trimmingCharacters(in: .whitespacesAndNewlines), environment: identity.environment))
        case .nodeRuntime(let identity): .nodeRuntime(.init(version: identity.version.trimmingCharacters(in: .whitespacesAndNewlines), environment: identity.environment))
        }
        guard !normalized.displayIdentifier.isEmpty else { return nil }
        return BatchIntent(operation: .uninstall, items: [normalized])
    }

    static func progress(for item: BatchItem, intent: BatchIntent?, running: BatchItem?, stage: ActivityTaskStage? = nil) -> CatalogCardProgress {
        progress(for: item, items: intent?.items ?? [], running: running, stage: stage)
    }

    private static func progress(for item: BatchItem, items: [BatchItem], running: BatchItem?, stage: ActivityTaskStage?) -> CatalogCardProgress {
        guard items.contains(item) else { return .idle }
        if stage == .reconciling { return .verifying }
        if item == running { return .running }
        guard let running, let currentIndex = items.firstIndex(of: running), let itemIndex = items.firstIndex(of: item) else { return .queued }
        return itemIndex > currentIndex ? .queued : .idle
    }
}

extension CatalogCardState {
    var batchItem: BatchItem {
        switch identity {
        case .homebrew(let identity): .homebrew(identity)
        case .npm(let identity): .npm(identity)
        }
    }
}
