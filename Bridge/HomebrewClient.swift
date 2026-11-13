import Foundation

enum HomebrewClientError: LocalizedError {
    case executableNotFound(String)
    case commandFailed(HomebrewCommandOutput)
    case invalidJSON(arguments: [String], detail: String)
    case invalidPlan(String)
    case stateChanged
    case scanIncomplete
    case alreadyInstalled(HomebrewPackageIdentity)
    case outputTruncated(arguments: [String])

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let path):
            "找不到 Homebrew 可执行文件：\(path)"
        case .commandFailed(let output):
            output.standardError.nilIfBlank
                ?? output.standardOutput.nilIfBlank
                ?? "brew \(output.arguments.joined(separator: " ")) 执行失败（\(output.terminationStatus)）"
        case .invalidJSON(_, let detail):
            "Homebrew 返回了无法识别的数据：\(detail)"
        case .invalidPlan(let detail):
            detail
        case .stateChanged:
            String(localized: ActivityItemReason.stateChanged.message)
        case .scanIncomplete:
            String(localized: ActivityItemReason.scanIncomplete.message)
        case .alreadyInstalled(let identity):
            "软件包已经安装：\(identity.name)"
        case .outputTruncated(let arguments):
            "brew \(arguments.joined(separator: " ")) 的输出超过安全上限"
        }
    }
}

actor HomebrewClient {
    private let brewURL: URL
    private let runner: ProcessRunner
    private let environment: [String: String]
    private let currentDirectoryURL: URL
    private let developerDirectoryProbeURL: URL
    private let caskRemovalScanner: CaskRemovalScanner
    private let caskRemovalAuthorizer: CaskRemovalAuthorizer?
    private let caskApplicationLifecycle: CaskApplicationLifecycle
    private var mutationInProgress = false

    init(
        brewURL: URL,
        runner: ProcessRunner,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory,
        userName: String = NSUserName(),
        developerDirectoryProbeURL: URL = URL(filePath: "/usr/bin/xcode-select"),
        caskRemovalScanner: CaskRemovalScanner? = nil,
        caskRemovalAuthorizer: CaskRemovalAuthorizer? = nil,
        caskApplicationLifecycle: CaskApplicationLifecycle = .live
    ) {
        self.brewURL = brewURL
        self.runner = runner
        self.currentDirectoryURL = homeDirectoryURL
        self.developerDirectoryProbeURL = developerDirectoryProbeURL
        self.caskRemovalScanner = caskRemovalScanner ?? CaskRemovalScanner(home: homeDirectoryURL)
        self.caskRemovalAuthorizer = caskRemovalAuthorizer
        self.caskApplicationLifecycle = caskApplicationLifecycle

        let prefix = brewURL.deletingLastPathComponent().deletingLastPathComponent().path
        self.environment = [
            "HOME": homeDirectoryURL.path,
            "PATH": [
                brewURL.deletingLastPathComponent().path,
                "\(prefix)/sbin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                "/usr/sbin",
                "/sbin",
            ].joined(separator: ":"),
            "TMPDIR": temporaryDirectoryURL.path,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "USER": userName,
            "LOGNAME": userName,
            "HOMEBREW_NO_ANALYTICS": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
            "HOMEBREW_NO_AUTO_UPDATE": "1",
        ]
    }

    func loadSnapshot(includingOutdated: Bool = true) async throws -> HomebrewSnapshot {
        try validateExecutable()
        let versionOutput = try await checkedRun(["--version"])
        let commandLineToolsAvailable = await probeCommandLineTools()
        var sectionErrors: [HomebrewSnapshot.Section: String] = [:]

        let configuration: HomebrewConfiguration
        do {
            configuration = try await loadConfiguration()
        } catch {
            configuration = HomebrewConfiguration(
                prefix: "",
                repository: "",
                cache: "",
                cellar: "",
                values: [:]
            )
            sectionErrors[.configuration] = error.localizedDescription
        }

        let installedPackages: [HomebrewPackage]
        do {
            let rawPackages = try await checkedRun(["info", "--json=v2", "--installed"])
            let envelope: BrewInfoEnvelope = try decode(rawPackages)
            installedPackages = packages(from: envelope)
        } catch {
            installedPackages = []
            sectionErrors[.packages] = error.localizedDescription
        }

        var outdated: [HomebrewOutdatedPackage] = []
        if includingOutdated {
            do { outdated = try await loadOutdatedPackages() }
            catch { sectionErrors[.outdated] = error.localizedDescription }
        }

        let taps: [HomebrewTap]
        do {
            let rawTaps = try await checkedRun(["tap-info", "--installed", "--json=v1"])
            let payload: [BrewTapPayload] = try decode(rawTaps)
            taps = payload.map(\.model).sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        } catch {
            taps = []
            sectionErrors[.taps] = error.localizedDescription
        }

        try Task.checkCancellation()
        return HomebrewSnapshot(
            executablePath: brewURL.path,
            version: try requiredLine(versionOutput, label: "version"),
            configuration: configuration,
            packages: installedPackages,
            outdatedPackages: outdated,
            taps: taps,
            sectionErrors: sectionErrors,
            controlledPath: environment["PATH", default: ""],
            commandLineToolsAvailable: commandLineToolsAvailable
        )
    }

    func loadOutdatedPackages() async throws -> [HomebrewOutdatedPackage] {
        try validateExecutable()
        let output = try await checkedRun(["outdated", "--json=v2"])
        let envelope: BrewOutdatedEnvelope = try decode(output)
        return envelope.models
    }

    func loadConfiguration() async throws -> HomebrewConfiguration {
        try validateExecutable()
        let prefixOutput = try await checkedRun(["--prefix"])
        let repositoryOutput = try await checkedRun(["--repository"])
        let cacheOutput = try await checkedRun(["--cache"])
        let cellarOutput = try await checkedRun(["--cellar"])
        let rawConfig = try await checkedRun(["config"])
        return HomebrewConfiguration(
            prefix: try requiredLine(prefixOutput, label: "prefix"),
            repository: try requiredLine(repositoryOutput, label: "repository"),
            cache: try requiredLine(cacheOutput, label: "cache"),
            cellar: try requiredLine(cellarOutput, label: "cellar"),
            values: parseConfiguration(rawConfig.standardOutput)
        )
    }

    func search(_ query: String) async throws -> [HomebrewSearchResult] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        try validateExecutable()

        let formulaResult = try await runSearch(term, kind: .formula)
        let caskResult = try await runSearch(term, kind: .cask)
        let results = formulaResult + caskResult
        return results.sorted {
            if $0.identity.kind != $1.identity.kind {
                return $0.identity.kind.sortOrder < $1.identity.kind.sortOrder
            }
            return $0.identity.name.localizedStandardCompare($1.identity.name) == .orderedAscending
        }
    }

    func search(_ query: String, kind: HomebrewPackageKind, limit: Int = 50) async throws -> [HomebrewSearchResult] {
        try Task.checkCancellation()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        guard term.utf8.count <= 512, (1...100).contains(limit) else {
            throw HomebrewClientError.invalidPlan("Invalid search query or result limit")
        }
        try validateExecutable()
        let results = try await runSearch(term, kind: kind)
        var seen = Set<HomebrewPackageIdentity>()
        return Array(results.filter { seen.insert($0.identity).inserted }
            .sorted { $0.identity.name.localizedStandardCompare($1.identity.name) == .orderedAscending }.prefix(limit))
    }

    func discover(_ query: String, kind: HomebrewPackageKind, limit: Int = 50) async throws -> [HomebrewPackage] {
        let matches = try await search(query, kind: kind, limit: limit)
        var packages: [HomebrewPackage] = []
        // Enrich only bounded matches, without fetching the full catalog.
        for match in matches {
            try Task.checkCancellation()
            packages.append(try await loadPackage(match.identity))
        }
        var seen = Set<HomebrewPackageIdentity>()
        return packages.filter { seen.insert($0.identity).inserted }
    }

    func loadPackage(_ identity: HomebrewPackageIdentity) async throws -> HomebrewPackage {
        try validateExecutable()
        let validatedIdentity = HomebrewPackageIdentity(
            name: try validatedPackageName(identity.name),
            kind: identity.kind
        )
        let result = try await checkedRun(infoArguments(for: validatedIdentity))
        let envelope: BrewInfoEnvelope = try decode(result)
        let returned = packages(from: envelope).filter { $0.identity.kind == validatedIdentity.kind }
        guard returned.count == 1, let package = returned.first else {
            throw HomebrewClientError.invalidJSON(arguments: result.arguments, detail: "未返回软件包信息")
        }
        let components = validatedIdentity.name.split(separator: "/").map(String.init)
        guard let requestedName = components.last else { throw HomebrewClientError.stateChanged }
        let canonicalName = package.identity.name.split(separator: "/").last.map(String.init)
        let sourceMatches = components.count == 1 || components.dropLast().joined(separator: "/") == package.tap
        let nameMatches = requestedName == canonicalName || package.aliases.contains(requestedName) || package.oldTokens.contains(requestedName)
        if !sourceMatches || !nameMatches {
            throw HomebrewClientError.invalidJSON(arguments: result.arguments, detail: "软件包身份与请求不匹配")
        }
        return package
    }

    func diagnose() async throws -> HomebrewDiagnosticReport {
        try validateExecutable()
        let result = try await run(["doctor"])
        let allLines = outputLines(result.standardOutput) + outputLines(result.standardError)
        let lines = Array(allLines.prefix(1_000))
        let diagnostics: [HomebrewDiagnostic]
        if result.standardOutputWasTruncated || result.standardErrorWasTruncated {
            diagnostics = [HomebrewDiagnostic(
                id: "doctor-output-truncated",
                severity: .error,
                message: "brew doctor 输出超过安全上限，当前诊断不完整"
            )]
        } else if lines.isEmpty, result.terminationStatus == 0 {
            diagnostics = [HomebrewDiagnostic(id: "healthy", severity: .info, message: "Your system is ready to brew.")]
        } else if lines.isEmpty {
            diagnostics = [HomebrewDiagnostic(
                id: "doctor-empty-error",
                severity: .error,
                message: "brew doctor 以非零状态结束，但没有返回诊断文本"
            )]
        } else {
            let defaultSeverity: HomebrewDiagnosticSeverity = result.terminationStatus == 0 ? .info : .warning
            var parsed = lines.enumerated().map { index, line in
                HomebrewDiagnostic(
                    id: "\(index):\(line)",
                    severity: diagnosticSeverity(for: line, default: defaultSeverity),
                    message: line
                )
            }
            if allLines.count > lines.count {
                parsed.append(HomebrewDiagnostic(
                    id: "doctor-line-limit",
                    severity: .warning,
                    message: "brew doctor 返回了过多诊断行，界面只显示前 \(lines.count) 条"
                ))
            }
            diagnostics = parsed
        }
        return HomebrewDiagnosticReport(diagnostics: diagnostics, command: result)
    }

    func planInstall(_ identity: HomebrewPackageIdentity) async throws -> HomebrewActionPlan {
        try await planInstall([identity])
    }

    func planInstall(_ identities: [HomebrewPackageIdentity]) async throws -> HomebrewActionPlan {
        guard !identities.isEmpty, identities.count <= 100 else {
            throw HomebrewClientError.invalidPlan("单次安装计划需要 1 至 100 个目标")
        }
        let validatedTargets = try identities.map {
            HomebrewPackageIdentity(name: try validatedPackageName($0.name), kind: $0.kind)
        }
        guard Set(validatedTargets).count == validatedTargets.count else {
            throw HomebrewClientError.invalidPlan("安装计划不能包含重复目标")
        }
        guard Set(validatedTargets.map(\.kind)).count == 1 else {
            throw HomebrewClientError.invalidPlan("单次安装不能混合 Formula 与 Cask")
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
            throw HomebrewClientError.invalidPlan("多个安装名称解析到了同一个软件包")
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
            throw HomebrewClientError.invalidPlan("升级计划至少需要一个目标")
        }
        let validatedTargets = try targets.map {
            HomebrewPackageIdentity(name: try validatedPackageName($0.name), kind: $0.kind)
        }
        guard Set(validatedTargets.map(\.kind)).count == 1 else {
            throw HomebrewClientError.invalidPlan("单次升级不能混合 Formula 与 Cask")
        }
        let targetPackages = try await loadTargetPackages(validatedTargets)
        let canonicalTargets = targetPackages.map(\.identity)
        guard Set(canonicalTargets).count == canonicalTargets.count else { throw HomebrewClientError.stateChanged }
        let snapshot = try await loadSnapshot()
        guard snapshot.sectionErrors[.outdated] == nil else {
            throw HomebrewClientError.invalidPlan("无法确认当前可升级项目")
        }
        let outdated = Set(snapshot.outdatedPackages.map(\.identity))
        guard canonicalTargets.allSatisfy(outdated.contains) else {
            throw HomebrewClientError.stateChanged
        }
        let packages = snapshot.outdatedPackages.filter { canonicalTargets.contains($0.identity) }
        guard packages.allSatisfy({ !$0.installedVersions.isEmpty && $0.currentVersion?.isEmpty == false }) else {
            throw HomebrewClientError.invalidPlan("无法确认升级目标的可用版本")
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
            throw HomebrewClientError.invalidPlan("无法确认当前 Tap 列表")
        }
        guard !snapshot.taps.contains(where: { $0.name == tapName }) else {
            throw HomebrewClientError.invalidPlan("Tap 已经安装：\(tapName)")
        }
        return plan(action: .addTap, tapName: tapName)
    }

    func planRemoveTap(_ name: String) async throws -> HomebrewActionPlan {
        let tapName = try validatedTapName(name)
        let snapshot = try await loadSnapshot()
        guard snapshot.sectionErrors[.taps] == nil,
              snapshot.sectionErrors[.packages] == nil
        else {
            throw HomebrewClientError.invalidPlan("无法确认 Tap 与已安装项目的关联状态")
        }
        guard snapshot.taps.contains(where: { $0.name == tapName }) else {
            throw HomebrewClientError.invalidPlan("Tap 未安装：\(tapName)")
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
            throw HomebrewClientError.invalidPlan("Formula 未安装：\(name)")
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
            throw HomebrewClientError.invalidPlan("Cask 未安装：\(name)")
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

    private func installedCaskroom() async throws -> URL {
        let output = try await checkedRun(["--caskroom"])
        let path = try requiredLine(output, label: "caskroom")
        guard CaskRemovalFileSystem.isNormalized(path) else { throw HomebrewClientError.stateChanged }
        return URL(filePath: path)
    }

    private func installedCaskSources(_ packages: [HomebrewPackage], caskroom: URL?) throws
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

    func execute(_ plan: HomebrewActionPlan, caskRemovalProgress: CaskRemovalProgressHandler? = nil) async throws -> HomebrewActionResult {
        guard !mutationInProgress else {
            throw HomebrewClientError.invalidPlan("已有 Homebrew 写操作正在执行")
        }
        mutationInProgress = true
        defer { mutationInProgress = false }
        let progress: CaskRemovalProgressReporter?
        if let removal = plan.caskRemoval, let caskRemovalProgress {
            progress = CaskRemovalProgressReporter(entries: removal.entries, handler: caskRemovalProgress)
        } else { progress = nil }
        await progress?.start()
        var installationRemoved = false
        do {
            var result = try await executeConfirmed(plan, progress: progress, installationRemoved: &installationRemoved)
            if let removal = plan.caskRemoval {
                let observed = await CaskRemovalPostflight.observe(removal: removal, failures: result.caskRemovalFailures,
                    installationRemoved: installationRemoved)
                result = HomebrewActionResult(plan: result.plan, command: result.command, snapshot: result.snapshot,
                    postflightError: result.postflightError, remainingResidualPaths: observed.remaining,
                    caskRemovalFailures: observed.failures, caskRemovalPathResults: observed.paths)
            }
            await progress?.finish(paths: result.caskRemovalPathResults)
            return result
        } catch {
            let paths: [CaskRemovalPathResult]
            if let removal = plan.caskRemoval {
                paths = await CaskRemovalPostflight.observe(removal: removal, failures: [],
                    installationRemoved: installationRemoved).paths
            } else { paths = [] }
            await progress?.finish(paths: paths)
            throw error
        }
    }

    private func executeConfirmed(_ plan: HomebrewActionPlan, progress: CaskRemovalProgressReporter?,
                                  installationRemoved: inout Bool) async throws -> HomebrewActionResult {
        guard plan.canExecute else {
            throw HomebrewClientError.invalidPlan("Tap 仍有关联的已安装软件包，不能移除")
        }
        guard Date().timeIntervalSince(plan.generatedAt) <= 300 else {
            throw HomebrewClientError.stateChanged
        }
        try validateExecutable()
        try await validateFreshness(of: plan)
        if let removal = plan.caskRemoval {
            guard plan.action == .uninstallCask, let target = plan.targets.first else { throw HomebrewClientError.stateChanged }
            let current = try await planCaskRemoval(target.name)
            guard current.caskRemoval?.ownershipFingerprint == removal.ownershipFingerprint,
                  current.caskRemoval?.installedMetadataFingerprint == removal.installedMetadataFingerprint,
                  current.caskRemoval?.entries.map({ "\($0.path)|\($0.disposition.rawValue)|\($0.fingerprint)" })
                    == removal.entries.map({ "\($0.path)|\($0.disposition.rawValue)|\($0.fingerprint)" }) else {
                throw HomebrewClientError.stateChanged
            }
            try caskRemovalScanner.validate(removal)
            try await caskApplicationLifecycle.quitApplications(removal.applicationIdentities)
        }
        let arguments = try arguments(for: plan)
        var actionEnvironment = environment
        actionEnvironment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        if plan.action == .uninstallFormula || plan.action == .uninstallCask || plan.action == .zapCask {
            actionEnvironment["HOMEBREW_NO_AUTOREMOVE"] = "1"
            actionEnvironment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        }
        if plan.caskRemoval != nil { actionEnvironment["HOMEBREW_NO_SUDO"] = "1" }
        for entry in plan.caskRemoval?.entries ?? [] where entry.disposition == .homebrew {
            await progress?.update(entry.path, status: .removing)
        }
        if let removal = plan.caskRemoval {
            try await validateFreshness(of: plan)
            let inventory = try await loadSnapshot(includingOutdated: false)
            guard inventory.sectionErrors[.packages] == nil, inventory.sectionErrors[.configuration] == nil else {
                throw HomebrewClientError.stateChanged
            }
            let caskroom = try await installedCaskroom()
            try await caskApplicationLifecycle.checkApplicationsAreStopped(removal.applicationIdentities)
            // No progress callbacks or quit waits may separate this final installation check from brew.
            let sources = try installedCaskSources(inventory.packages, caskroom: caskroom)
            guard sources.fingerprint == removal.installedMetadataFingerprint else { throw HomebrewClientError.stateChanged }
            for entry in removal.entries where entry.disposition == .homebrew {
                guard try CaskRemovalFileSystem.fingerprint(entry.path) == entry.fingerprint else {
                    throw HomebrewClientError.stateChanged
                }
            }
        }
        let output = try await run(
            arguments,
            environment: actionEnvironment,
            timeout: .seconds(1_800)
        )
        do {
            let snapshot = try await loadSnapshot()
            // Preserve the observed installation state even if later cleanup is interrupted.
            installationRemoved = snapshot.sectionErrors[.packages] == nil
                && !snapshot.packages.contains { plan.targets.contains($0.identity) && $0.isInstalled }
            var cleanupFailures: [CaskRemovalFailure] = []
            if let removal = plan.caskRemoval, output.terminationStatus == 0,
               installationRemoved {
                for entry in removal.entries where entry.disposition == .homebrew {
                    await progress?.update(entry.path, status: CaskRemovalFileSystem.exists(entry.path) ? .retained : .removed)
                }
                do { cleanupFailures = try await cleanCaskRemoval(removal, progress: progress) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    cleanupFailures = removal.entries.filter { $0.disposition == .remove && CaskRemovalFileSystem.exists($0.path) }
                        .map { .init(path: $0.path, error: error) }
                }
            }
            return HomebrewActionResult(
                plan: plan,
                command: output,
                snapshot: snapshot,
                postflightError: nil,
                remainingResidualPaths: plan.caskRemoval == nil ? remainingResidualPaths(from: plan) : [],
                caskRemovalFailures: cleanupFailures
            )
        } catch is CancellationError { throw CancellationError() }
        catch {
            return HomebrewActionResult(
                plan: plan,
                command: output,
                snapshot: nil,
                postflightError: error.localizedDescription,
                remainingResidualPaths: plan.caskRemoval == nil ? remainingResidualPaths(from: plan) : []
            )
        }
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

    private func cleanCaskRemoval(_ removal: CaskRemovalPlan, progress: CaskRemovalProgressReporter?) async throws -> [CaskRemovalFailure] {
        try await caskApplicationLifecycle.withApplicationsStopped(removal.applicationIdentities, onInvalidation: {}) {
            try await self.cleanConfirmedCaskRemoval(removal, progress: progress)
        }
    }

    private func cleanConfirmedCaskRemoval(_ removal: CaskRemovalPlan, progress: CaskRemovalProgressReporter?) async throws -> [CaskRemovalFailure] {
        let candidates = removal.entries.filter { $0.disposition == .remove }
        var failures: [CaskRemovalFailure] = []
        var authorizationNeeded: [CaskRemovalEntry] = []
        let verification = try caskRemovalScanner.makeVerificationSession(removal)
        for entry in candidates {
            try Task.checkCancellation()
            guard CaskRemovalFileSystem.exists(entry.path) else {
                await progress?.update(entry.path, status: .removed)
                continue
            }
            do {
                await progress?.update(entry.path, status: .removing)
                try await caskApplicationLifecycle.checkApplicationsAreStopped(removal.applicationIdentities)
                // Recheck ownership after all suspension points, immediately before filesystem mutation.
                if entry.category != .homebrewCache {
                    guard try verification.sharedDataRemainsProtected() else {
                        throw HomebrewClientError.stateChanged
                    }
                }
                guard try verification.cacheOwnershipIsUnchanged(entry) else {
                    throw HomebrewClientError.stateChanged
                }
                try CaskRemovalFileSystem.remove(entry, shouldContinue: Task.checkCancellation)
                guard !CaskRemovalFileSystem.exists(entry.path) else { throw HomebrewClientError.stateChanged }
                await progress?.update(entry.path, status: .removed)
            } catch let error as POSIXError where error.code == .EACCES || error.code == .EPERM {
                if caskRemovalAuthorizer != nil,
                   CaskRemovalAuthorizationRequest.allows(entry.path, home: CaskRemovalFileSystem.physicalURL(currentDirectoryURL).path) {
                    authorizationNeeded.append(entry)
                } else {
                    failures.append(.init(path: entry.path, error: error))
                    await progress?.update(entry.path, status: .retained)
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                failures.append(.init(path: entry.path, error: error))
                await progress?.update(entry.path, status: .retained)
            }
        }
        if let caskRemovalAuthorizer, !authorizationNeeded.isEmpty {
            do {
                try await caskApplicationLifecycle.checkApplicationsAreStopped(removal.applicationIdentities)
                let authorizationFailures = try await caskRemovalAuthorizer.remove(authorizationNeeded, home: currentDirectoryURL,
                    removal: removal, applicationLifecycle: caskApplicationLifecycle)
                failures += authorizationFailures
                let failedPaths = Set(authorizationFailures.map(\.path))
                for entry in authorizationNeeded {
                    let removed = !failedPaths.contains(entry.path) && !CaskRemovalFileSystem.exists(entry.path)
                    await progress?.update(entry.path, status: removed ? .removed : .retained)
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                failures += authorizationNeeded.map { .init(path: $0.path, error: error) }
                for entry in authorizationNeeded { await progress?.update(entry.path, status: .retained) }
            }
        }
        return failures
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

    private func validateFreshness(of plan: HomebrewActionPlan) async throws {
        if plan.action == .install || plan.action == .upgrade {
            guard plan.confirmedTargets.count == plan.targets.count else { throw HomebrewClientError.stateChanged }
            let packages = try await loadTargetPackages(plan.targets)
            guard try await confirmedTargets(packages) == plan.confirmedTargets else { throw HomebrewClientError.stateChanged }
        }
        switch plan.action {
        case .install:
            guard !plan.targets.isEmpty else {
                throw HomebrewClientError.invalidPlan("安装计划缺少目标")
            }
            var packages: [HomebrewPackage] = []
            packages.reserveCapacity(plan.targets.count)
            for target in plan.targets {
                packages.append(try await loadPackage(target))
            }
            guard packages.allSatisfy({ !$0.isInstalled }),
                  packagesFingerprint(packages) == plan.stateFingerprint
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
                throw HomebrewClientError.invalidPlan("Tap 操作缺少名称")
            }
            let current = try await planRemoveTap(tapName)
            guard current.associatedPackages == plan.associatedPackages, current.canExecute else {
                throw HomebrewClientError.stateChanged
            }
        case .uninstallFormula, .uninstallCask, .zapCask:
            guard let target = plan.targets.first else {
                throw HomebrewClientError.invalidPlan("卸载计划缺少目标")
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
                throw HomebrewClientError.invalidPlan("Tap 操作缺少名称")
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

    private func remainingResidualPaths(from plan: HomebrewActionPlan) -> [HomebrewResidualPath] {
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

    private func arguments(for plan: HomebrewActionPlan) throws -> [String] {
        switch plan.action {
        case .install:
            return try packageCommand("install", targets: plan.targets)
        case .upgrade:
            return try packageCommand("upgrade", targets: plan.targets)
        case .update:
            return ["update"]
        case .addTap:
            return ["tap", try requiredTapName(plan)]
        case .removeTap:
            return ["untap", try requiredTapName(plan)]
        case .uninstallFormula:
            return try singleTargetCommand(["uninstall", "--formula"], plan: plan, kind: .formula)
        case .uninstallCask:
            return try singleTargetCommand(["uninstall", "--cask"], plan: plan, kind: .cask)
        case .zapCask:
            return try singleTargetCommand(["uninstall", "--cask", "--zap"], plan: plan, kind: .cask)
        }
    }

    private func packageCommand(_ verb: String, targets: [HomebrewPackageIdentity]) throws -> [String] {
        guard !targets.isEmpty else {
            throw HomebrewClientError.invalidPlan("操作计划没有目标")
        }
        let kinds = Set(targets.map(\.kind))
        guard kinds.count == 1, let kind = kinds.first else {
            throw HomebrewClientError.invalidPlan("单次操作不能混合 Formula 与 Cask")
        }
        return [verb, kind == .formula ? "--formula" : "--cask"]
            + (try targets.map { try validatedPackageName($0.name) })
    }

    private func singleTargetCommand(
        _ prefix: [String],
        plan: HomebrewActionPlan,
        kind: HomebrewPackageKind
    ) throws -> [String] {
        guard plan.targets.count == 1, plan.targets[0].kind == kind else {
            throw HomebrewClientError.invalidPlan("卸载计划目标无效")
        }
        return prefix + [try validatedPackageName(plan.targets[0].name)]
    }

    private func requiredTapName(_ plan: HomebrewActionPlan) throws -> String {
        guard let name = plan.tapName else {
            throw HomebrewClientError.invalidPlan("Tap 操作缺少名称")
        }
        return try validatedTapName(name)
    }

    private func validatedTapName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !trimmed.hasPrefix("-"),
              trimmed.unicodeScalars.allSatisfy(Self.packageNameCharacters.contains)
        else {
            throw HomebrewClientError.invalidPlan("Tap 名称必须使用 owner/repository 格式")
        }
        return trimmed
    }

    private func validatedPackageName(_ name: String) throws -> String {
        guard !name.isEmpty,
              !name.hasPrefix("-"),
              name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              name.unicodeScalars.allSatisfy(Self.packageNameCharacters.contains)
        else {
            throw HomebrewClientError.invalidPlan("Homebrew 软件包名称无效：\(name)")
        }
        return name
    }

    private static let packageNameCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@+._-/"
    )

    private func infoArguments(for identity: HomebrewPackageIdentity) -> [String] {
        ["info", "--json=v2", identity.kind == .formula ? "--formula" : "--cask", identity.name]
    }

    private func runSearch(_ query: String, kind: HomebrewPackageKind) async throws -> [HomebrewSearchResult] {
        let result = try await run(["search", kind == .formula ? "--formula" : "--cask", "--", query])
        guard !result.standardOutputWasTruncated, !result.standardErrorWasTruncated else {
            throw HomebrewClientError.outputTruncated(arguments: result.arguments)
        }
        if result.terminationStatus != 0 {
            let message = result.standardError + "\n" + result.standardOutput
            guard message.localizedCaseInsensitiveContains("No formulae or casks found") else {
                throw HomebrewClientError.commandFailed(result)
            }
            return []
        }
        return outputLines(result.standardOutput)
            .filter { !$0.hasPrefix("==>") }
            .map { HomebrewSearchResult(identity: HomebrewPackageIdentity(name: $0, kind: kind)) }
    }

    private func checkedRun(_ arguments: [String]) async throws -> HomebrewCommandOutput {
        let result = try await run(arguments)
        guard !result.standardOutputWasTruncated, !result.standardErrorWasTruncated else {
            throw HomebrewClientError.outputTruncated(arguments: result.arguments)
        }
        guard result.terminationStatus == 0 else {
            throw HomebrewClientError.commandFailed(result)
        }
        return result
    }

    private func run(
        _ arguments: [String],
        environment overrideEnvironment: [String: String]? = nil,
        timeout: Duration? = .seconds(300)
    ) async throws -> HomebrewCommandOutput {
        let result = try await runner.run(ProcessRequest(
            executableURL: brewURL,
            arguments: arguments,
            environment: overrideEnvironment ?? environment,
            currentDirectoryURL: currentDirectoryURL,
            timeout: timeout
        ))
        return HomebrewCommandOutput(
            arguments: arguments,
            standardOutput: result.outputText,
            standardError: result.errorText,
            terminationStatus: result.terminationStatus,
            standardOutputWasTruncated: result.standardOutputWasTruncated,
            standardErrorWasTruncated: result.standardErrorWasTruncated
        )
    }

    private func validateExecutable() throws {
        guard brewURL.isFileURL, brewURL.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: brewURL.path) else {
            throw HomebrewClientError.executableNotFound(brewURL.path)
        }
    }

    private func probeCommandLineTools() async -> Bool {
        guard developerDirectoryProbeURL.isFileURL,
              FileManager.default.isExecutableFile(atPath: developerDirectoryProbeURL.path)
        else { return false }
        guard let result = try? await runner.run(ProcessRequest(
            executableURL: developerDirectoryProbeURL,
            arguments: ["-p"],
            environment: environment,
            currentDirectoryURL: currentDirectoryURL,
            timeout: .seconds(10),
            standardOutputLimit: 16 * 1_024,
            standardErrorLimit: 16 * 1_024
        )) else { return false }
        return result.terminationStatus == 0
            && !result.outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func decode<Payload: Decodable>(_ result: HomebrewCommandOutput) throws -> Payload {
        do {
            return try JSONDecoder().decode(Payload.self, from: Data(result.standardOutput.utf8))
        } catch {
            throw HomebrewClientError.invalidJSON(arguments: result.arguments, detail: error.localizedDescription)
        }
    }

    private func requiredLine(_ output: HomebrewCommandOutput, label: String) throws -> String {
        guard let line = outputLines(output.standardOutput).first else {
            throw HomebrewClientError.invalidJSON(arguments: output.arguments, detail: "缺少 \(label)")
        }
        return line
    }

    private func outputLines(_ value: String) -> [String] {
        value.split(whereSeparator: \.isNewline).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private func parseConfiguration(_ value: String) -> [String: String] {
        outputLines(value).reduce(into: [:]) { result, line in
            guard let separator = line.firstIndex(of: ":") else { return }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let item = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return }
            result[key] = item
        }
    }

    private func packages(from envelope: BrewInfoEnvelope) -> [HomebrewPackage] {
        (envelope.formulae.map(\.model) + envelope.casks.map(\.model)).sorted {
            if $0.identity.kind != $1.identity.kind {
                return $0.identity.kind.sortOrder < $1.identity.kind.sortOrder
            }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private func diagnosticSeverity(
        for line: String,
        default defaultSeverity: HomebrewDiagnosticSeverity
    ) -> HomebrewDiagnosticSeverity {
        if line.localizedCaseInsensitiveContains("error") {
            return .error
        }
        if line.localizedCaseInsensitiveContains("warning")
            || line.localizedCaseInsensitiveContains("problem")
        {
            return .warning
        }
        return defaultSeverity
    }
}

// Error exits finalize unresolved rows without inventing successful deletion events.
private actor CaskRemovalProgressReporter {
    let entries: [CaskRemovalEntry]
    let handler: CaskRemovalProgressHandler
    private var statuses: [String: CaskRemovalPathStatus] = [:]

    init(entries: [CaskRemovalEntry], handler: @escaping CaskRemovalProgressHandler) {
        self.entries = entries
        self.handler = handler
    }

    func start() async {
        for entry in entries {
            await update(entry.path, status: entry.disposition == .protected ? .retained : .pending)
        }
    }

    func update(_ path: String, status: CaskRemovalPathStatus) async {
        guard statuses[path] != status else { return }
        statuses[path] = status
        await handler(.init(path: path, status: status))
    }

    func finish(paths: [CaskRemovalPathResult]) async {
        for result in paths { await update(result.path, status: result.progress.status) }
        for entry in entries where statuses[entry.path] == .pending || statuses[entry.path] == .removing {
            await update(entry.path, status: .retained)
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
