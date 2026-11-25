import Darwin
import CryptoKit
import Foundation

// Inspired by Mole's exact app identity and surviving-copy guards, implemented for Cellar's typed plans.
struct CaskRemovalScanner: Sendable {
    let home: URL
    let applicationRoots: [URL]
    let maximumScanEntries: Int
    let applicationAliasRoots: [URL]
    let mountedVolumesOverride: [CaskRemovalVolume]?
    let hasExplicitApplicationRoots: Bool

    init(home: URL, applicationRoots: [URL]? = nil, maximumScanEntries: Int = 20_000,
         mountedVolumes: [CaskRemovalVolume]? = nil,
         systemApplicationRoots: [URL] = [URL(filePath: "/System/Applications"), URL(filePath: "/System/Cryptexes/App/System/Applications")]) {
        self.hasExplicitApplicationRoots = applicationRoots != nil
        self.applicationAliasRoots = systemApplicationRoots
        self.mountedVolumesOverride = mountedVolumes
        self.maximumScanEntries = maximumScanEntries
        self.home = CaskRemovalFileSystem.physicalURL(home)
        self.applicationRoots = applicationRoots ?? [
            URL(filePath: "/Applications"), self.home.appending(path: "Applications"),
            URL(filePath: "/Library/Input Methods"), self.home.appending(path: "Library/Input Methods")
        ]
    }

    func scan(package: HomebrewPackage, cache: URL, otherCasks: [HomebrewPackage], confirmedCachePath: URL? = nil,
              caskroom: URL? = nil, installedMetadataIsComplete: Bool = true) throws -> CaskRemovalPlan {
        try Task.checkCancellation()
        var warnings = Set<CaskRemovalWarning>()
        let budget = CaskRemovalScanBudget(entries: maximumScanEntries)
        let locations = try appLocations(package, caskroom: caskroom, budget: budget)
        let apps = locations.urls
        if !locations.complete { warnings.insert(.incompleteScan) }
        guard apps.count <= 128 else { throw POSIXError(.E2BIG) }
        var metadata: [AppIdentity] = []
        for app in apps {
            do {
                try budget.check()
                if let identity = try readApp(app, budget: budget) { metadata.append(identity) }
            } catch is CancellationError { throw CancellationError() }
            catch { warnings.insert(.incompleteScan); break }
        }
        var additionalApps: [URL] = []
        var otherLocationsComplete = true
        for other in otherCasks {
            try budget.check()
            if other.identity.kind == .cask && other.identity != package.identity {
                let otherLocations = try appLocations(other, caskroom: caskroom, budget: budget)
                additionalApps += otherLocations.urls
                otherLocationsComplete = otherLocationsComplete && otherLocations.complete
            }
        }
        let discovered = try inventory(additionalApps: additionalApps, budget: budget)
        let inventory = AppInventory(apps: discovered.apps,
                                     complete: discovered.complete && otherLocationsComplete && installedMetadataIsComplete)
        let targets = Set(apps.map(\.path))
        let targetFiles = Set(metadata.compactMap(\.appFileIdentity))
        let survivors = inventory.apps.filter { app in
            !targets.contains(app.url.path) && !(app.appFileIdentity.map(targetFiles.contains) ?? false)
        }
        var shared = false
        for target in metadata {
            try Task.checkCancellation()
            if survivors.contains(where: { sameFamily(target, $0) }) { shared = true; break }
        }
        var survivorLeaves: [String: Set<String>] = [:]
        for (relative, _) in Self.dataDirectories {
            try Task.checkCancellation()
            survivorLeaves[relative] = Set(survivors.flatMap { leaves(app: $0, directory: relative).map { $0.lowercased() } })
        }
        if shared { warnings.insert(.sharedData) }
        if !inventory.complete || metadata.count != apps.count || apps.isEmpty { warnings.insert(.incompleteScan) }
        if package.artifacts.contains(where: { $0.kind == "uninstall" }) {
            warnings.insert(.uninstallerRequiresAuthorization)
        }
        let preserveData = shared || !inventory.complete || !locations.complete || metadata.count != apps.count
        var candidates: [String: (CaskRemovalCategory, CaskRemovalDisposition)] = [:]
        for app in apps { candidates[app.path] = (.application, .homebrew) }
        for app in metadata {
            for (relative, category) in Self.dataDirectories {
                let root = home.appending(path: "Library/\(relative)")
                for leaf in leaves(app: app, directory: relative) {
                    try Task.checkCancellation()
                    let claimedBySurvivor = survivorLeaves[relative, default: []].contains(leaf.lowercased())
                    if claimedBySurvivor { warnings.insert(.sharedData) }
                    candidates[root.appending(path: leaf).path] = (category, preserveData || claimedBySurvivor ? .protected : .remove)
                }
            }
        }
        let exactPaths = exactRelatedPaths(package)
        let otherClaims = otherCasks.filter { $0.identity != package.identity && $0.identity.kind == .cask }
            .flatMap { other in
                other.artifacts.filter { $0.category == .zap && ($0.kind == "trash" || $0.kind == "delete") }
                    .flatMap(\.values).compactMap { CaskRemovalPathPolicy.ownershipClaim($0, home: home) }
            }
        let survivorRelatedPaths = survivorLeaves.flatMap { directory, leaves in
            leaves.map { home.appending(path: "Library/" + directory + "/" + $0).path }
        }
        let protectedDerivedPaths = candidates.filter { $0.value.1 == .protected }.map(\.key)
        let vendorComponents = Set(metadata.flatMap { $0.bundleID.lowercased().split(separator: ".").dropFirst().dropLast().map(String.init) })
        for candidate in exactPaths {
            try budget.check()
            let sharedPath = otherClaims.contains { $0.protects(candidate.path) }
                || survivorRelatedPaths.contains { CaskRemovalPathPolicy.overlaps(candidate.path, $0) }
            let vendorParent = vendorComponents.contains(URL(filePath: candidate.path).lastPathComponent.lowercased())
                || exactPaths.contains { $0.path != candidate.path && $0.path.hasPrefix(candidate.path + "/") }
            let keep = candidate.isSharedContainer || preserveData || metadata.isEmpty || sharedPath || vendorParent
                || protectedDerivedPaths.contains { CaskRemovalPathPolicy.overlaps(candidate.path, $0) }
            if sharedPath { warnings.insert(.sharedData) }
            candidates[candidate.path] = (candidate.category, keep ? .protected : .remove)
        }
        // Shared ownership applies to inferred paths too, not just the paths explicitly listed in zap.
        for (path, classification) in candidates where classification.1 == .remove {
            let sharedPath = otherClaims.contains { $0.protects(path) }
                || survivorRelatedPaths.contains { CaskRemovalPathPolicy.overlaps(path, $0) }
            if sharedPath || vendorComponents.contains(URL(filePath: path).lastPathComponent.lowercased()) {
                candidates[path] = (classification.0, .protected)
                if sharedPath { warnings.insert(.sharedData) }
            }
        }
        let token = package.identity.name.split(separator: "/").last.map(String.init) ?? package.identity.name
        // Formula and Cask downloads can use the same token prefix.
        let cacheCollision = otherCasks.contains {
            $0.identity != package.identity && $0.identity.name.split(separator: "/").last.map(String.init) == token
        }
        if cacheCollision { warnings.insert(.sharedData) }
        try collectCache(token: token, cache: cache, protected: cacheCollision,
                     confirmedCachePath: confirmedCachePath,
                     candidates: &candidates, warnings: &warnings, budget: budget)
        func ancestorKeys(_ path: String) -> [String] {
            var parent = URL(filePath: path).deletingLastPathComponent()
            var paths: [String] = []
            while parent.path != "/" {
                paths.append(CaskRemovalPathPolicy.comparisonKey(parent.path))
                parent.deleteLastPathComponent()
            }
            return paths
        }
        // Protection comes from the complete candidate set, even when later fingerprinting runs out of budget.
        var protectedPaths = Set<String>()
        for (path, classification) in candidates where classification.1 == .protected {
            try Task.checkCancellation()
            protectedPaths.insert(CaskRemovalPathPolicy.comparisonKey(path))
            protectedPaths.formUnion(ancestorKeys(path))
        }
        var entries: [CaskRemovalEntry] = []
        for (path, classification) in candidates.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            do {
                try budget.check()
                guard CaskRemovalFileSystem.exists(path) else { continue }
                let fingerprint = try CaskRemovalFileSystem.fingerprint(path)
                entries.append(.init(path: path, category: classification.0, estimatedBytes: nil,
                                     disposition: protectedPaths.contains(CaskRemovalPathPolicy.comparisonKey(path)) ? .protected : classification.1,
                                     fingerprint: fingerprint))
            } catch is CancellationError { throw CancellationError() }
            catch let error as POSIXError where error.code == .ETIMEDOUT {
                warnings.insert(.incompleteScan)
                break
            }
            catch {
                warnings.insert(.incompleteScan)
                entries.append(.init(path: path, category: classification.0, estimatedBytes: nil,
                                     disposition: .protected, fingerprint: "unreadable", sizeFailure: Self.sizeFailure(error)))
            }
        }
        // Fingerprint failures add protection using the same case/Unicode semantics as ownership checks.
        for entry in entries where entry.disposition == .protected {
            try Task.checkCancellation()
            protectedPaths.insert(CaskRemovalPathPolicy.comparisonKey(entry.path))
            protectedPaths.formUnion(ancestorKeys(entry.path))
        }
        let dominantPaths = Set(entries.filter {
            $0.disposition != .protected && !protectedPaths.contains(CaskRemovalPathPolicy.comparisonKey($0.path))
        }.map { CaskRemovalPathPolicy.comparisonKey($0.path) })
        entries = try entries.compactMap { entry in
            try Task.checkCancellation()
            guard !ancestorKeys(entry.path).contains(where: dominantPaths.contains) else { return nil }
            return CaskRemovalEntry(path: entry.path, category: entry.category, estimatedBytes: entry.estimatedBytes,
                disposition: protectedPaths.contains(CaskRemovalPathPolicy.comparisonKey(entry.path)) ? .protected : entry.disposition,
                fingerprint: entry.fingerprint, sizeFailure: entry.sizeFailure)
        }
        // Size is observational: keeping a path never skips measurement or changes deletion eligibility.
        let sizeBudget = CaskRemovalScanBudget(entries: maximumScanEntries, duration: .seconds(2))
        entries = try entries.map { entry in
            try Task.checkCancellation()
            guard entry.sizeFailure == nil else { return entry }
            do {
                let bytes = try CaskRemovalFileSystem.measureAllocatedSize(entry.path, budget: sizeBudget)
                return CaskRemovalEntry(path: entry.path, category: entry.category, estimatedBytes: bytes,
                    disposition: entry.disposition, fingerprint: entry.fingerprint)
            } catch is CancellationError { throw CancellationError() }
            catch {
                warnings.insert(.incompleteScan)
                return CaskRemovalEntry(path: entry.path, category: entry.category, estimatedBytes: nil,
                    disposition: entry.disposition, fingerprint: entry.fingerprint, sizeFailure: Self.sizeFailure(error))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let ownership = String(decoding: try encoder.encode(inventory), as: UTF8.self)
        return CaskRemovalPlan(displayName: package.displayName, appURL: apps.first, entries: entries,
            warnings: warnings.sorted { $0.rawValue < $1.rawValue }, ownershipFingerprint: ownership,
            applicationIdentities: metadata.map { .init(bundleURL: $0.url, bundleIdentifier: $0.bundleID) })
    }

    private static func sizeFailure(_ error: Error) -> CaskRemovalSizeFailure {
        if let error = error as? POSIXError {
            return switch error.code {
            case .EACCES, .EPERM: .permissionDenied
            case .ETIMEDOUT: .limitReached
            case .EXDEV, .ELOOP: .unsafePath
            case .ENOENT, .ENOTDIR: .notFound
            default: .ioFailure
            }
        }
        if let error = error as? HomebrewClientError, case .stateChanged = error { return .fileChanged }
        return .ioFailure
    }

    func validate(_ plan: CaskRemovalPlan) throws {
        for entry in plan.entries where entry.disposition != .protected {
            try Task.checkCancellation()
            guard try CaskRemovalFileSystem.fingerprint(entry.path) == entry.fingerprint else {
                throw HomebrewClientError.stateChanged
            }
        }
    }

    func sharedDataRemainsProtected(_ plan: CaskRemovalPlan) throws -> Bool {
        do { return try makeVerificationSession(plan).sharedDataRemainsProtected() }
        catch is CancellationError { throw CancellationError() }
        catch { return false }
    }

    func cacheOwnershipIsUnchanged(_ entry: CaskRemovalEntry, plan: CaskRemovalPlan, budget: CaskRemovalScanBudget = .init()) throws -> Bool {
        try Task.checkCancellation()
        guard entry.category == .homebrewCache,
              URL(filePath: entry.path).deletingLastPathComponent().lastPathComponent == "downloads" else { return true }
        let cache = URL(filePath: entry.path).deletingLastPathComponent().deletingLastPathComponent()
        do {
            try budget.check()
            let files = try cacheFiles(cache, budget: budget)
            let confirmed = Set(plan.entries.filter { $0.disposition == .remove }.map(\.path))
            for file in files {
                try budget.check()
                if !confirmed.contains(file.path), try cacheTarget(file, cache: cache)?.path == entry.path { return false }
            }
            return true
        } catch is CancellationError { throw CancellationError() }
        catch { throw HomebrewClientError.scanIncomplete }
    }

    func makeVerificationSession(_ plan: CaskRemovalPlan) throws -> VerificationSession {
        try VerificationSession(scanner: self, plan: plan)
    }

    // Each pass still discovers new/changed apps. Only unchanged metadata is reused within this cleanup.
    final class VerificationSession {
        private let scanner: CaskRemovalScanner
        private let plan: CaskRemovalPlan
        private let before: AppInventory
        private let beforeApps: Set<AppIdentity>
        private var cachedApps: [String: AppIdentity]

        init(scanner: CaskRemovalScanner, plan: CaskRemovalPlan) throws {
            try Task.checkCancellation()
            self.scanner = scanner
            self.plan = plan
            before = try JSONDecoder().decode(AppInventory.self, from: Data(plan.ownershipFingerprint.utf8))
            beforeApps = Set(before.apps)
            cachedApps = Dictionary(uniqueKeysWithValues: before.apps.map { ($0.url.path, $0) })
        }

        func sharedDataRemainsProtected() throws -> Bool {
            try Task.checkCancellation()
            guard before.complete else { throw HomebrewClientError.scanIncomplete }
            let budget = CaskRemovalScanBudget(entries: scanner.maximumScanEntries)
            let current = try scanner.inventory(additionalApps: before.apps.map(\.url), budget: budget, cachedApps: cachedApps)
            guard current.complete else { throw HomebrewClientError.scanIncomplete }
            cachedApps = Dictionary(uniqueKeysWithValues: current.apps.map { ($0.url.path, $0) })
            let removed = Set(plan.entries.filter { $0.category == .application }.map(\.path))
            return current.apps.filter { !removed.contains($0.url.path) }.allSatisfy(beforeApps.contains)
                && removed.allSatisfy { !CaskRemovalFileSystem.exists($0) }
        }

        func cacheOwnershipIsUnchanged(_ entry: CaskRemovalEntry) throws -> Bool {
            try scanner.cacheOwnershipIsUnchanged(entry, plan: plan,
                budget: CaskRemovalScanBudget(entries: scanner.maximumScanEntries))
        }
    }

    struct AppIdentity: Codable, Hashable {
        let url: URL
        let bundleID: String
        let name: String
        let fingerprint: String
        var appFileIdentity: String? = nil
        var infoFileIdentity: String? = nil
    }

    struct AppInventory: Codable {
        let apps: [AppIdentity]
        let complete: Bool
    }

    struct AppLocations {
        let urls: [URL]
        let complete: Bool
    }
}
