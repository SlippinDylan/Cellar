import Darwin
import CryptoKit
import Foundation

// Inspired by Mole's exact app identity and surviving-copy guards, implemented for Cellar's typed plans.
struct CaskRemovalScanner: Sendable {
    let home: URL
    let applicationRoots: [URL]
    let maximumScanEntries: Int
    private let applicationAliasRoots: [URL]
    private let mountedVolumesOverride: [CaskRemovalVolume]?
    private let hasExplicitApplicationRoots: Bool

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

    private struct AppIdentity: Codable, Hashable {
        let url: URL
        let bundleID: String
        let name: String
        let fingerprint: String
        var appFileIdentity: String? = nil
        var infoFileIdentity: String? = nil
    }

    private struct AppInventory: Codable {
        let apps: [AppIdentity]
        let complete: Bool
    }

    private struct AppLocations {
        let urls: [URL]
        let complete: Bool
    }

    private struct InstalledConfiguration: Decodable {
        struct Layer: Decodable { let appdir: String? }
        let defaults: Layer?
        let env: Layer?
        let explicit: Layer?
        enum CodingKeys: String, CodingKey { case defaults = "default", env, explicit }
    }

    private func exactRelatedPaths(_ package: HomebrewPackage) -> [CaskRemovalPathPolicy.RelatedPath] {
        package.artifacts.filter { $0.category == .zap && ($0.kind == "trash" || $0.kind == "delete") }
            .flatMap(\.values).compactMap { CaskRemovalPathPolicy.relatedPath($0, home: home) }
    }

    private func appLocations(_ package: HomebrewPackage, caskroom: URL?, budget: CaskRemovalScanBudget) throws -> AppLocations {
        try budget.check()
        let artifacts = package.artifacts.filter { $0.category == .installed && $0.kind == "app" }
        let applications = artifacts.compactMap(\.application)
        var complete = applications.count == artifacts.count
        var directory: URL? = hasExplicitApplicationRoots ? applicationRoots.first : nil
        let declared = package.artifacts.filter { $0.category == .installed }.flatMap(\.uninstallDeletePaths)
        // Installed uninstall-only receipts omit pkg, but retain its exact app deletion evidence.
        let hasPackageInstaller = package.artifacts.contains { $0.category == .installed && $0.kind == "pkg" }
            || declared.contains { applicationPath($0)?.pathExtension.lowercased() == "app" }
        let needsDirectory = hasPackageInstaller || applications.contains { $0.target?.hasPrefix("/") != true && $0.target?.hasPrefix("~/") != true }
        if needsDirectory {
            if let caskroom {
                do {
                    let token = package.installedCaskToken ?? package.identity.name.split(separator: "/").last.map(String.init) ?? ""
                    guard token.range(of: #"^[A-Za-z0-9][A-Za-z0-9@+._-]*$"#, options: .regularExpression) != nil else {
                        throw HomebrewClientError.stateChanged
                    }
                    let config = try CaskRemovalFileSystem.readRegularFile(caskroom.appending(path: token + "/.metadata/config.json").path,
                        limit: 65_536, shouldContinue: budget.check)
                    let saved = try JSONDecoder().decode(InstalledConfiguration.self, from: config)
                    let value = saved.explicit?.appdir ?? saved.env?.appdir ?? saved.defaults?.appdir ?? "/Applications"
                    guard let resolved = applicationPath(value), resolved.path != "/" else { throw HomebrewClientError.stateChanged }
                    directory = resolved
                } catch is CancellationError { throw CancellationError() }
                catch { complete = false; directory = nil }
            } else if !hasExplicitApplicationRoots { complete = false }
        }
        var urls: [URL] = []
        for application in applications {
            try budget.check()
            let destination = application.target ?? URL(filePath: application.source).lastPathComponent
            let value: String
            if destination.hasPrefix("/") || destination.hasPrefix("~/") { value = destination }
            else if let directory { value = directory.path + "/" + destination }
            else { complete = false; continue }
            guard let url = applicationPath(value), url.pathExtension.lowercased() == "app" else { complete = false; continue }
            urls.append(url)
        }
        if hasPackageInstaller {
            let roots = applicationRoots + [directory].compactMap { $0 }
            let pkgApps = declared.compactMap { value -> URL? in
                guard let url = applicationPath(value), url.pathExtension.lowercased() == "app",
                      roots.contains(where: { url.path.hasPrefix($0.path + "/") }) else { return nil }
                return url
            }
            if pkgApps.isEmpty { complete = false }
            urls += pkgApps
        }
        return AppLocations(urls: Array(Set(urls)).sorted { $0.path < $1.path }, complete: complete)
    }

    private func applicationPath(_ value: String) -> URL? {
        let path = value.hasPrefix("~/") ? home.path + "/" + String(value.dropFirst(2)) : value
        guard CaskRemovalFileSystem.isNormalized(path), !path.hasPrefix("/Volumes/"),
              !path.contains(where: { "*?[]{}".contains($0) }) else { return nil }
        return URL(filePath: path)
    }

    private func readApp(_ url: URL, budget: CaskRemovalScanBudget, volume: CaskRemovalVolume? = nil, cached: AppIdentity? = nil) throws -> AppIdentity? {
        try Task.checkCancellation()
        guard volume != nil || !url.path.hasPrefix("/Volumes/") else { return nil }
        do { return try readAppMetadata(url, budget: budget, volume: volume, cached: cached) }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    private func readAppMetadata(_ url: URL, budget: CaskRemovalScanBudget, volume: CaskRemovalVolume?, cached: AppIdentity?) throws -> AppIdentity? {
        var directory = false
        try CaskRemovalFileSystem.walk(url.path, budget: budget, volume: volume) { node, _ in
            directory = node.isDirectory
            return false
        }
        guard directory else { return nil }
        let info = url.appending(path: "Contents/Info.plist")
        guard let identity = try? CaskRemovalFileSystem.fingerprint(url.path),
              let infoIdentityBefore = try? CaskRemovalFileSystem.fingerprint(info.path) else { return nil }
        if let cached, cached.url == url, cached.appFileIdentity == identity, cached.infoFileIdentity == infoIdentityBefore {
            return cached
        }
        let data = try CaskRemovalFileSystem.readRegularFile(info.path, limit: 1_048_576, shouldContinue: budget.check)
        guard infoIdentityBefore == (try? CaskRemovalFileSystem.fingerprint(info.path)),
              let infoIdentity = try? CaskRemovalFileSystem.fingerprint(info.path),
              (try? CaskRemovalFileSystem.fingerprint(url.path)) == identity,
              let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundle = dictionary["CFBundleIdentifier"] as? String,
              bundle.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$"#, options: .regularExpression) != nil else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return AppIdentity(url: url, bundleID: bundle, name: url.deletingPathExtension().lastPathComponent,
                           fingerprint: identity + ":" + infoIdentity + ":" + digest,
                           appFileIdentity: identity, infoFileIdentity: infoIdentity)
    }

    private func readApplicationAlias(_ url: URL, budget: CaskRemovalScanBudget) throws -> AppIdentity? {
        try budget.check()
        let before = try CaskRemovalFileSystem.fingerprint(url.path)
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        let destination = link.hasPrefix("/") ? link : url.deletingLastPathComponent().path + "/" + link
        guard let target = CaskRemovalFileSystem.lexicalURL(destination) else { return nil }
        // Resolve only aliases into approved application roots, never arbitrary link destinations.
        for root in applicationRoots + applicationAliasRoots {
            try budget.check()
            guard target.deletingLastPathComponent().path == root.path else { continue }
            let physicalRoot = applicationAliasRoots.contains(root) ? CaskRemovalFileSystem.physicalURL(root) : root
            let physicalTarget = physicalRoot.appending(path: target.lastPathComponent)
            guard let app = try readApp(physicalTarget, budget: budget),
                  before == (try CaskRemovalFileSystem.fingerprint(url.path)) else { return nil }
            return AppIdentity(url: url, bundleID: app.bundleID, name: app.name,
                               fingerprint: before + ":alias:" + app.fingerprint)
        }
        return nil
    }

    private func mountedVolumes(budget: CaskRemovalScanBudget) throws -> [CaskRemovalVolume] {
        if let mountedVolumesOverride { return mountedVolumesOverride }
        guard applicationRoots.contains(where: { $0.path == "/Applications" }) else { return [] }
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { throw POSIXError(.EIO) }
        var volumes: [CaskRemovalVolume] = []
        for index in 0..<Int(count) {
            try budget.check()
            let mountedAt = withUnsafePointer(to: &mounts[index].f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let fileSystem = withUnsafePointer(to: &mounts[index].f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) { String(cString: $0) }
            }
            let local = mounts[index].f_flags & UInt32(MNT_LOCAL) != 0
            // macOS's idle auto_home map is not an installed-app volume.
            let systemHomeMap = fileSystem == "autofs" && mountedAt == "/System/Volumes/Data/home"
            if mountedAt.hasPrefix("/Volumes/") || (!local && !systemHomeMap) {
                volumes.append(.init(url: URL(filePath: mountedAt), identity: .init(mounts[index]), isLocal: local))
            }
        }
        return volumes
    }

    private func inventory(additionalApps: [URL], budget: CaskRemovalScanBudget, cachedApps: [String: AppIdentity] = [:]) throws -> AppInventory {
        var result: [AppIdentity] = []
        var complete = true
        var seen = Set<String>()
        do {
            let volumes = try mountedVolumes(budget: budget)
            for url in additionalApps {
                try budget.check()
                // Mounted paths are checked only through the current, identity-bound volume inventory.
                if url.path.hasPrefix("/Volumes/") || volumes.contains(where: { url.path == $0.url.path || url.path.hasPrefix($0.url.path + "/") }) { continue }
                guard CaskRemovalFileSystem.exists(url.path), seen.insert(url.path).inserted else { continue }
                if let app = try readApp(url, budget: budget, cached: cachedApps[url.path]) { result.append(app) } else { complete = false }
            }
            func collect(_ node: CaskRemovalFileSystem.ScanNode, depth: Int, volume: CaskRemovalVolume?) throws -> Bool {
                let url = URL(filePath: node.path)
                let app = (volume == nil || depth > 0) && url.pathExtension.lowercased() == "app"
                // Same discovery scope as Mole: top-level apps and the Applications subtree.
                if volume != nil && depth == 1 && !app && url.lastPathComponent.caseInsensitiveCompare("Applications") != .orderedSame {
                    return false
                }
                if node.isSymbolicLink {
                    if volume != nil || depth == 0 {
                        complete = false
                    } else if app {
                        if let identity = try readApplicationAlias(url, budget: budget) {
                            if seen.insert(node.path).inserted { result.append(identity) }
                        } else {
                            complete = false
                        }
                    }
                    return false
                }
                if app {
                    if seen.insert(node.path).inserted {
                        if let identity = try readApp(url, budget: budget, volume: volume, cached: cachedApps[url.path]) { result.append(identity) }
                        else { complete = false }
                    }
                    return false
                }
                if depth >= 12 { complete = false; return false }
                return true
            }
            for root in applicationRoots {
                try budget.check()
                guard !root.path.hasPrefix("/Volumes/") else { complete = false; continue }
                guard CaskRemovalFileSystem.exists(root.path) else { continue }
                do {
                    try CaskRemovalFileSystem.walk(root.path, budget: budget) { node, depth in
                        try collect(node, depth: depth, volume: nil)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { complete = false }
            }
            for volume in volumes {
                try budget.check()
                guard volume.isLocal else { complete = false; continue }
                do {
                    try CaskRemovalFileSystem.walk(volume.url.path, budget: budget, volume: volume) { node, depth in
                        try collect(node, depth: depth, volume: volume)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { complete = false }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { complete = false }
        return AppInventory(apps: result.sorted { $0.url.path < $1.url.path }, complete: complete)
    }

    private func sameFamily(_ first: AppIdentity, _ second: AppIdentity) -> Bool {
        let a = first.bundleID.lowercased(), b = second.bundleID.lowercased()
        return a == b || a.hasPrefix(b + ".") || b.hasPrefix(a + ".") || familyName(first.name) == familyName(second.name)
    }

    private func familyName(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: #"[ -](beta|nightly|alpha|dev|canary|preview|insider|stable)( edition)?$"#,
                                             with: "", options: .regularExpression)
    }

    private func leaves(app: AppIdentity, directory: String) -> [String] {
        if directory == "Preferences" { return [app.bundleID + ".plist"] }
        if directory == "Saved Application State" { return [app.bundleID + ".savedState"] }
        if directory == "Cookies" { return [app.bundleID + ".binarycookies"] }
        if directory == "LaunchAgents" { return [app.bundleID + ".plist"] }
        if directory == "Containers" || directory == "Application Scripts" { return [app.bundleID] }
        var names = [app.bundleID]
        let name = app.name
        let generic: Set<String> = ["local", "system", "node", "cache", "google", "microsoft", "adobe", "apple"]
        if name.count >= 4, !generic.contains(name.lowercased()), !name.contains("/"), !name.contains("..") {
            names += [name, name.replacingOccurrences(of: " ", with: ""), name.replacingOccurrences(of: " ", with: "-").lowercased()]
        }
        return Array(Set(names))
    }

    private static let dataDirectories: [(String, CaskRemovalCategory)] = [
        ("Caches", .cache), ("Logs", .cache), ("HTTPStorages", .cache), ("WebKit", .cache),
        ("Application Support", .applicationData), ("Preferences", .applicationData),
        ("Containers", .applicationData), ("Application Scripts", .applicationData),
        ("Saved Application State", .applicationData), ("Cookies", .applicationData), ("LaunchAgents", .applicationData)
    ]

    private func cacheFiles(_ cache: URL, budget: CaskRemovalScanBudget) throws -> [URL] {
        var files: [URL] = []
        try CaskRemovalFileSystem.walk(cache.path, budget: budget) { node, depth in
            if depth == 0 { return true }
            if node.isRegularFile || node.isSymbolicLink { files.append(URL(filePath: node.path)) }
            return false
        }
        return files
    }

    // Resolve only a direct cache-local alias, never realpath an arbitrary symlink destination.
    private func cacheTarget(_ file: URL, cache: URL) throws -> URL? {
        try Task.checkCancellation()
        var value = stat()
        guard lstat(file.path, &value) == 0 else { throw POSIXError(.EIO) }
        if value.st_mode & S_IFMT == S_IFREG { return file }
        guard value.st_mode & S_IFMT == S_IFLNK else { return nil }
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: file.path)
        let path = target.hasPrefix("/") ? target : cache.path + "/" + target
        guard let normalized = CaskRemovalFileSystem.lexicalURL(path),
              normalized.deletingLastPathComponent().path == cache.appending(path: "downloads").path else { return nil }
        return normalized
    }

    private func collectCache(token: String, cache: URL, protected: Bool, confirmedCachePath: URL?,
        candidates: inout [String: (CaskRemovalCategory, CaskRemovalDisposition)], warnings: inout Set<CaskRemovalWarning>,
        budget: CaskRemovalScanBudget) throws {
        do {
            try budget.check()
            guard CaskRemovalFileSystem.exists(cache.path) else { return }
            let files = try cacheFiles(cache, budget: budget)
            let owned = Set(files.filter {
                $0.lastPathComponent.hasPrefix(token + "--") && !$0.lastPathComponent.contains(".bottle.")
            }.map(\.path))
            var targets: [String: URL] = [:]
            var otherTargets = Set<String>()
            for file in files {
                try budget.check()
                if let target = try cacheTarget(file, cache: cache) {
                    targets[file.path] = target
                    if !owned.contains(file.path) { otherTargets.insert(target.path) }
                }
            }
            let confirmed = confirmedCachePath.flatMap { CaskRemovalFileSystem.lexicalURL($0.path) }
            if confirmed == nil { warnings.insert(.incompleteScan) }
            if let confirmed, confirmed.deletingLastPathComponent().path == cache.appending(path: "downloads").path {
                try budget.check()
                // The FD walk verifies ancestors, filesystem and regular-file type without following links.
                var regular = false
                do {
                    try CaskRemovalFileSystem.walk(confirmed.path, budget: budget) { node, _ in
                        regular = node.isRegularFile
                        return false
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { warnings.insert(.incompleteScan) }
                if regular {
                    candidates[confirmed.path] = (.homebrewCache, protected || otherTargets.contains(confirmed.path) ? .protected : .remove)
                }
            }
            for path in owned {
                try budget.check()
                candidates[path] = (.homebrewCache, protected || targets[path]?.path != confirmed?.path || confirmed == nil ? .protected : .remove)
            }
        } catch is CancellationError { throw CancellationError() }
        catch { warnings.insert(.incompleteScan) }
    }
}
