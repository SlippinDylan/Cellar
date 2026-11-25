import Foundation

extension HomebrewClient {
    func planInstall(_ identity: HomebrewPackageIdentity) async throws -> HomebrewActionPlan {
        try await planInstall([identity])
    }

    func planInstall(_ identities: [HomebrewPackageIdentity]) async throws -> HomebrewActionPlan {
        guard !identities.isEmpty, identities.count <= 100 else {
            throw HomebrewClientError.invalidPlan("An install plan requires 1 to 100 targets")
        }
        let validatedTargets = try identities.map {
            HomebrewPackageIdentity(name: try validatedPackageName($0.name), kind: $0.kind)
        }
        guard Set(validatedTargets).count == validatedTargets.count else {
            throw HomebrewClientError.invalidPlan("An install plan cannot contain duplicate targets")
        }
        guard Set(validatedTargets.map(\.kind)).count == 1 else {
            throw HomebrewClientError.invalidPlan("Cannot mix Formula and Cask targets in a single install")
        }

        var packages: [HomebrewPackage] = []
        packages.reserveCapacity(validatedTargets.count)
        for target in validatedTargets {
            let package = try await loadPackage(target)
            guard !package.isInstalled else {
                throw HomebrewClientError.alreadyInstalled(package.identity)
            }
            packages.append(package)
        }
        guard Set(packages.map(\.identity)).count == packages.count else {
            throw HomebrewClientError.invalidPlan("Multiple install names resolved to the same canonical package")
        }
        return plan(
            action: .install,
            targets: packages.map(\.identity),
            stateFingerprint: packagesFingerprint(packages),
            confirmedTargets: try await confirmedTargets(packages)
        )
    }

    func planUpgrade(_ targets: [HomebrewPackageIdentity]) async throws -> HomebrewActionPlan {
        guard !targets.isEmpty else {
            throw HomebrewClientError.invalidPlan("An upgrade plan requires at least one target")
        }
        let validatedTargets = try targets.map {
            HomebrewPackageIdentity(name: try validatedPackageName($0.name), kind: $0.kind)
        }
        guard Set(validatedTargets.map(\.kind)).count == 1 else {
            throw HomebrewClientError.invalidPlan("Cannot mix Formula and Cask targets in a single upgrade")
        }
        let targetPackages = try await loadTargetPackages(validatedTargets)
        let canonicalTargets = targetPackages.map(\.identity)
        guard Set(canonicalTargets).count == canonicalTargets.count else { throw HomebrewClientError.stateChanged }
        let snapshot = try await loadSnapshot()
        guard snapshot.sectionErrors[.outdated] == nil else {
            throw HomebrewClientError.invalidPlan("Unable to verify currently outdated packages")
        }
        let outdated = Set(snapshot.outdatedPackages.map(\.identity))
        guard canonicalTargets.allSatisfy(outdated.contains) else {
            throw HomebrewClientError.stateChanged
        }
        let packages = snapshot.outdatedPackages.filter { canonicalTargets.contains($0.identity) }
        guard packages.allSatisfy({ !$0.installedVersions.isEmpty && $0.currentVersion?.isEmpty == false }) else {
            throw HomebrewClientError.invalidPlan("Unable to verify available version for upgrade target")
        }
        let confirmed = try await confirmedTargets(targetPackages)
        guard confirmed.allSatisfy({ target in packages.contains { $0.identity == target.identity && $0.currentVersion == target.version } })
        else { throw HomebrewClientError.stateChanged }
        return plan(
            action: .upgrade,
            targets: canonicalTargets,
            stateFingerprint: upgradeFingerprint(packages),
            confirmedTargets: confirmed
        )
    }

    func planUpdate() throws -> HomebrewActionPlan {
        try validateExecutable()
        return plan(action: .update)
    }

    func planAddTap(_ name: String) async throws -> HomebrewActionPlan {
        let tapName = try validatedTapName(name)
        let snapshot = try await loadSnapshot()
        guard snapshot.sectionErrors[.taps] == nil else {
            throw HomebrewClientError.invalidPlan("Unable to verify installed taps")
        }
        guard !snapshot.taps.contains(where: { $0.name == tapName }) else {
            throw HomebrewClientError.invalidPlan("Tap is already installed: \(tapName)")
        }
        return plan(action: .addTap, tapName: tapName)
    }

    func planRemoveTap(_ name: String) async throws -> HomebrewActionPlan {
        let tapName = try validatedTapName(name)
        let snapshot = try await loadSnapshot()
        guard snapshot.sectionErrors[.taps] == nil,
              snapshot.sectionErrors[.packages] == nil
        else {
            throw HomebrewClientError.invalidPlan("Unable to verify tap associations with installed packages")
        }
        guard snapshot.taps.contains(where: { $0.name == tapName }) else {
            throw HomebrewClientError.invalidPlan("Tap is not installed: \(tapName)")
        }
        let associated = snapshot.packages
            .filter { $0.tap == tapName }
            .map(\.identity)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return plan(action: .removeTap, tapName: tapName, associatedPackages: associated)
    }

    func planFormulaUninstall(_ name: String) async throws -> HomebrewActionPlan {
        let identity = HomebrewPackageIdentity(name: name, kind: .formula)
        let package = try await loadPackage(identity)
        guard package.isInstalled else {
            throw HomebrewClientError.invalidPlan("Formula is not installed: \(name)")
        }
        let usesResult = try await checkedRun(["uses", "--installed", "--formula", package.identity.name])
        return plan(
            action: .uninstallFormula,
            targets: [package.identity],
            dependencies: package.dependencies,
            dependents: outputLines(usesResult.standardOutput),
            stateFingerprint: packageFingerprint(package)
                + "|uses:" + outputLines(usesResult.standardOutput).joined(separator: ",")
        )
    }

    func planCaskUninstall(_ name: String, zap: Bool) async throws -> HomebrewActionPlan {
        let identity = HomebrewPackageIdentity(name: name, kind: .cask)
        let package = try await loadPackage(identity)
        guard package.isInstalled else {
            throw HomebrewClientError.invalidPlan("Cask is not installed: \(name)")
        }
        let relevantArtifacts = package.artifacts.filter { zap || $0.category == .installed }
        return plan(
            action: zap ? .zapCask : .uninstallCask,
            targets: [package.identity],
            artifacts: relevantArtifacts,
            residualPaths: scanResidualPaths(in: relevantArtifacts),
            stateFingerprint: packageFingerprint(package)
        )
    }

    func planCaskRemoval(_ name: String) async throws -> HomebrewActionPlan {
        let package = try await loadPackage(.init(name: name, kind: .cask))
        guard package.isInstalled else { throw HomebrewClientError.stateChanged }
        let inventory = try await loadSnapshot(includingOutdated: false)
        guard inventory.sectionErrors[.packages] == nil, inventory.sectionErrors[.configuration] == nil else {
            throw HomebrewClientError.stateChanged
        }
        let confirmedCache: URL?
        do {
            let cache = try await checkedRun(["--cache", "--cask", package.identity.name])
            let path = try requiredLine(cache, label: "cask cache")
            guard path.hasPrefix("/"), !path.contains("\n") else { throw HomebrewClientError.stateChanged }
            confirmedCache = URL(filePath: path)
        } catch is CancellationError { throw CancellationError() }
        catch { confirmedCache = nil } // Cache discovery is independent; ambiguous downloads stay protected.
        let caskroom: URL?
        do {
            caskroom = try await installedCaskroom()
        } catch is CancellationError { throw CancellationError() }
        catch { caskroom = nil }
        let sources = try installedCaskSources(inventory.packages, caskroom: caskroom)
        guard let installedPackage = sources.packages.first(where: { $0.identity == package.identity }) else {
            throw HomebrewClientError.stateChanged
        }
        var removal = try caskRemovalScanner.scan(package: installedPackage, cache: URL(filePath: inventory.configuration.cache),
            otherCasks: sources.packages, confirmedCachePath: confirmedCache, caskroom: caskroom,
            installedMetadataIsComplete: sources.isComplete)
        removal.installedMetadataFingerprint = sources.fingerprint
        return plan(action: .uninstallCask, targets: [package.identity], artifacts: installedPackage.artifacts,
            residualPaths: removal.entries.map { .init(path: $0.path, artifactKind: $0.category.rawValue, estimatedBytes: $0.estimatedBytes) },
            stateFingerprint: packageFingerprint(package), caskRemoval: removal)
    }

    func installedCaskroom() async throws -> URL {
        let output = try await checkedRun(["--caskroom"])
        let path = try requiredLine(output, label: "caskroom")
        guard CaskRemovalFileSystem.isNormalized(path) else { throw HomebrewClientError.stateChanged }
        return URL(filePath: path)
    }

    func installedCaskSources(_ packages: [HomebrewPackage], caskroom: URL?) throws
        -> (packages: [HomebrewPackage], fingerprint: String, isComplete: Bool) {
        let budget = CaskRemovalScanBudget()
        var fingerprints: [String] = []
        var isComplete = true
        let installed = try packages.map { package -> HomebrewPackage in
            guard package.identity.kind == .cask else { return package }
            var artifacts: [HomebrewCaskArtifact] = []
            var installedToken: String?
            do {
                guard let caskroom else { throw HomebrewClientError.scanIncomplete }
                let metadata = try CaskInstalledMetadata.read(package: package, caskroom: caskroom, budget: budget)
                artifacts = metadata.artifacts
                installedToken = metadata.installedToken
                fingerprints.append("\(package.identity.name)=\(metadata.fingerprint)")
            } catch is CancellationError { throw CancellationError() }
            catch {
                // Current catalog definitions cannot authorize deletion for an unknown installation.
                isComplete = false
                fingerprints.append("\(package.identity.name)=unavailable")
            }
            return HomebrewPackage(identity: package.identity, displayName: package.displayName,
                description: package.description, homepage: package.homepage, installedVersions: package.installedVersions,
                currentVersion: package.currentVersion, tap: package.tap, dependencies: package.dependencies,
                pinned: package.pinned, deprecated: package.deprecated, disabled: package.disabled, artifacts: artifacts,
                oldTokens: package.oldTokens, installedCaskToken: installedToken)
        }
        return (installed, fingerprints.sorted().joined(separator: "|"), isComplete)
    }


    private func plan(
        action: HomebrewAction,
        targets: [HomebrewPackageIdentity] = [],
        tapName: String? = nil,
        dependencies: [String] = [],
        dependents: [String] = [],
        artifacts: [HomebrewCaskArtifact] = [],
        residualPaths: [HomebrewResidualPath] = [],
        associatedPackages: [HomebrewPackageIdentity] = [],
        stateFingerprint: String? = nil,
        caskRemoval: CaskRemovalPlan? = nil,
        confirmedTargets: [HomebrewConfirmedTarget] = []
    ) -> HomebrewActionPlan {
        HomebrewActionPlan(
            id: UUID(),
            action: action,
            targets: targets,
            tapName: tapName,
            dependencies: dependencies,
            dependents: dependents,
            artifacts: artifacts,
            residualPaths: residualPaths,
            associatedPackages: associatedPackages,
            generatedAt: Date(),
            stateFingerprint: stateFingerprint,
            confirmedTargets: confirmedTargets,
            caskRemoval: caskRemoval
        )
    }


    private func loadTargetPackages(_ targets: [HomebrewPackageIdentity]) async throws -> [HomebrewPackage] {
        var packages: [HomebrewPackage] = []
        for target in targets { packages.append(try await loadPackage(target)) }
        return packages
    }

    private func confirmedTargets(_ packages: [HomebrewPackage]) async throws -> [HomebrewConfirmedTarget] {
        let configuration = try await loadConfiguration()
        return try packages.map { package in
            guard let source = package.tap, !source.isEmpty, let version = package.currentVersion, !version.isEmpty,
                  configuration.prefix.hasPrefix("/") else { throw HomebrewClientError.stateChanged }
            return .init(identity: package.identity, source: source, version: version, prefix: configuration.prefix)
        }
    }

    func renewBatchPlan(_ confirmed: HomebrewActionPlan) async throws -> HomebrewActionPlan? {
        guard confirmed.action == .install || confirmed.action == .upgrade,
              confirmed.confirmedTargets.count == confirmed.targets.count else { throw HomebrewClientError.stateChanged }
        let packages = try await loadTargetPackages(confirmed.targets)
        guard try await confirmedTargets(packages) == confirmed.confirmedTargets else { throw HomebrewClientError.stateChanged }
        if zip(packages, confirmed.confirmedTargets).allSatisfy({ $0.installedVersions.contains($1.version) }) { return nil }
        if confirmed.action == .install, packages.contains(where: \.isInstalled) { throw HomebrewClientError.stateChanged }
        let current = try await (confirmed.action == .install ? planInstall(confirmed.targets) : planUpgrade(confirmed.targets))
        guard current.confirmedTargets == confirmed.confirmedTargets,
              current.stateFingerprint == confirmed.stateFingerprint else { throw HomebrewClientError.stateChanged }
        return current
    }

    func validateFreshness(of plan: HomebrewActionPlan) async throws {
        let targetPackages: [HomebrewPackage]
        if plan.action == .install || plan.action == .upgrade {
            guard plan.confirmedTargets.count == plan.targets.count else { throw HomebrewClientError.stateChanged }
            targetPackages = try await loadTargetPackages(plan.targets)
            guard try await confirmedTargets(targetPackages) == plan.confirmedTargets else { throw HomebrewClientError.stateChanged }
        } else {
            targetPackages = []
        }
        switch plan.action {
        case .install:
            guard !plan.targets.isEmpty else {
                throw HomebrewClientError.invalidPlan("Install plan is missing targets")
            }
            guard targetPackages.allSatisfy({ !$0.isInstalled }),
                  packagesFingerprint(targetPackages) == plan.stateFingerprint
            else {
                throw HomebrewClientError.stateChanged
            }
        case .upgrade:
            let snapshot = try await loadSnapshot()
            guard snapshot.sectionErrors[.outdated] == nil,
                  upgradeFingerprint(snapshot.outdatedPackages.filter { plan.targets.contains($0.identity) }) == plan.stateFingerprint
            else {
                throw HomebrewClientError.stateChanged
            }
            let outdated = Set(snapshot.outdatedPackages.map(\.identity))
            guard plan.targets.allSatisfy(outdated.contains) else {
                throw HomebrewClientError.stateChanged
            }
        case .removeTap:
            guard let tapName = plan.tapName else {
                throw HomebrewClientError.invalidPlan("Tap operation is missing a tap name")
            }
            let current = try await planRemoveTap(tapName)
            guard current.associatedPackages == plan.associatedPackages, current.canExecute else {
                throw HomebrewClientError.stateChanged
            }
        case .uninstallFormula, .uninstallCask, .zapCask:
            guard let target = plan.targets.first else {
                throw HomebrewClientError.invalidPlan("Uninstall plan is missing a target")
            }
            let package = try await loadPackage(target)
            let currentFingerprint: String
            if plan.action == .uninstallFormula {
                let uses = try await checkedRun(["uses", "--installed", "--formula", package.identity.name])
                currentFingerprint = packageFingerprint(package)
                    + "|uses:" + outputLines(uses.standardOutput).joined(separator: ",")
            } else {
                currentFingerprint = packageFingerprint(package)
            }
            guard package.isInstalled, currentFingerprint == plan.stateFingerprint else {
                throw HomebrewClientError.stateChanged
            }
        case .addTap:
            guard let tapName = plan.tapName else {
                throw HomebrewClientError.invalidPlan("Tap operation is missing a tap name")
            }
            let snapshot = try await loadSnapshot()
            guard snapshot.sectionErrors[.taps] == nil,
                  !snapshot.taps.contains(where: { $0.name == tapName })
            else {
                throw HomebrewClientError.stateChanged
            }
        case .update:
            break
        }
    }

    private func packageFingerprint(_ package: HomebrewPackage) -> String {
        let artifacts = package.artifacts.map(\.id).sorted().joined(separator: ",")
        return [
            package.identity.kind.rawValue,
            package.identity.name,
            package.installedVersions.sorted().joined(separator: ","),
            package.currentVersion ?? "",
            package.dependencies.sorted().joined(separator: ","),
            artifacts,
        ].joined(separator: "|")
    }

    private func packagesFingerprint(_ packages: [HomebrewPackage]) -> String {
        packages
            .map { "\($0.identity.kind.rawValue):\($0.identity.name)=\(packageFingerprint($0))" }
            .sorted()
            .joined(separator: "||")
    }

    private func upgradeFingerprint(_ packages: [HomebrewOutdatedPackage]) -> String {
        packages.map {
            [$0.identity.kind.rawValue, $0.identity.name, $0.installedVersions.sorted().joined(separator: ","), $0.currentVersion ?? ""].joined(separator: "|")
        }.sorted().joined(separator: "||")
    }

    private func scanResidualPaths(in artifacts: [HomebrewCaskArtifact]) -> [HomebrewResidualPath] {
        var seen = Set<String>()
        return artifacts.flatMap { artifact in
            artifact.values.flatMap { value in
                candidateURLs(for: value, artifactKind: artifact.kind).compactMap { url in
                    let path = url.standardizedFileURL.path
                    guard seen.insert(path).inserted,
                          FileManager.default.fileExists(atPath: path)
                    else { return nil }
                    return HomebrewResidualPath(
                        path: path,
                        artifactKind: artifact.kind,
                        estimatedBytes: allocatedSize(at: url)
                    )
                }
            }
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func candidateURLs(for value: String, artifactKind: String) -> [URL] {
        guard !value.isEmpty,
              !value.contains("*"),
              !value.contains("?"),
              !value.contains("["),
              !value.contains("{")
        else { return [] }
        if value.hasPrefix("~/") {
            return [currentDirectoryURL.appending(path: String(value.dropFirst(2)))]
        }
        if value.hasPrefix("/") {
            return [URL(filePath: value)]
        }
        if artifactKind == "app", value.hasSuffix(".app"), !value.contains("/") {
            return [
                URL(filePath: "/Applications", directoryHint: .isDirectory).appending(path: value),
                currentDirectoryURL.appending(path: "Applications", directoryHint: .isDirectory)
                    .appending(path: value),
            ]
        }
        return []
    }

    private func allocatedSize(at url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        if let total = values.totalFileAllocatedSize, total > 0 {
            return Int64(total)
        }
        guard url.pathExtension.localizedCaseInsensitiveCompare("app") != .orderedSame else {
            return nil
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return nil }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(150))
        var total: Int64 = 0
        var visited = 0
        for case let itemURL as URL in enumerator {
            visited += 1
            if visited > 10_000 || clock.now >= deadline { return nil }
            guard let item = try? itemURL.resourceValues(forKeys: keys) else { continue }
            total += Int64(item.totalFileAllocatedSize ?? item.fileAllocatedSize ?? 0)
        }
        return total
    }

    func remainingResidualPaths(from plan: HomebrewActionPlan) -> [HomebrewResidualPath] {
        plan.residualPaths.compactMap { residual in
            let url = URL(filePath: residual.path)
            guard plan.caskRemoval != nil ? CaskRemovalFileSystem.exists(url.path) : FileManager.default.fileExists(atPath: url.path) else { return nil }
            return HomebrewResidualPath(
                path: residual.path,
                artifactKind: residual.artifactKind,
                // Postflight reports remaining paths without starting another recursive scan.
                estimatedBytes: plan.caskRemoval != nil ? nil : allocatedSize(at: url)
            )
        }
    }

}
