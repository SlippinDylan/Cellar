import Foundation

enum HomebrewClientError: LocalizedError {
    case executableNotFound(String)
    case commandFailed(HomebrewCommandOutput)
    case invalidJSON(arguments: [String], detail: String)
    case invalidPlan(String)
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
    private var mutationInProgress = false

    init(
        brewURL: URL,
        runner: ProcessRunner,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory,
        userName: String = NSUserName(),
        developerDirectoryProbeURL: URL = URL(filePath: "/usr/bin/xcode-select")
    ) {
        self.brewURL = brewURL
        self.runner = runner
        self.currentDirectoryURL = homeDirectoryURL
        self.developerDirectoryProbeURL = developerDirectoryProbeURL

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

    func loadSnapshot() async throws -> HomebrewSnapshot {
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

        let outdated: [HomebrewOutdatedPackage]
        do {
            let rawOutdated = try await checkedRun(["outdated", "--json=v2"])
            let envelope: BrewOutdatedEnvelope = try decode(rawOutdated)
            outdated = envelope.models
        } catch {
            outdated = []
            sectionErrors[.outdated] = error.localizedDescription
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

    func loadPackage(_ identity: HomebrewPackageIdentity) async throws -> HomebrewPackage {
        try validateExecutable()
        let validatedIdentity = HomebrewPackageIdentity(
            name: try validatedPackageName(identity.name),
            kind: identity.kind
        )
        let result = try await checkedRun(infoArguments(for: validatedIdentity))
        let envelope: BrewInfoEnvelope = try decode(result)
        guard let package = packages(from: envelope).first(where: { $0.identity == validatedIdentity })
            ?? packages(from: envelope).first
        else {
            throw HomebrewClientError.invalidJSON(arguments: result.arguments, detail: "未返回软件包信息")
        }
        return package
    }

    func diagnose() async throws -> HomebrewDiagnosticReport {
        try validateExecutable()
        let result = try await run(["doctor"])
        let lines = outputLines(result.standardOutput) + outputLines(result.standardError)
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
            diagnostics = lines.enumerated().map { index, line in
            HomebrewDiagnostic(
                id: "\(index):\(line)",
                severity: diagnosticSeverity(for: line, default: defaultSeverity),
                message: line
            )
        }
        }
        return HomebrewDiagnosticReport(diagnostics: diagnostics, command: result)
    }

    func planInstall(_ identity: HomebrewPackageIdentity) async throws -> HomebrewActionPlan {
        let package = try await loadPackage(identity)
        guard !package.isInstalled else {
            throw HomebrewClientError.invalidPlan("软件包已经安装：\(package.identity.name)")
        }
        return plan(
            action: .install,
            targets: [package.identity],
            stateFingerprint: packageFingerprint(package)
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
        let snapshot = try await loadSnapshot()
        guard snapshot.sectionErrors[.outdated] == nil else {
            throw HomebrewClientError.invalidPlan("无法确认当前可升级项目")
        }
        let outdated = Set(snapshot.outdatedPackages.map(\.identity))
        guard validatedTargets.allSatisfy(outdated.contains) else {
            throw HomebrewClientError.invalidPlan("升级目标已经变化，请刷新后重试")
        }
        return plan(
            action: .upgrade,
            targets: validatedTargets,
            stateFingerprint: identitiesFingerprint(validatedTargets)
        )
    }

    func planUpdate() -> HomebrewActionPlan {
        plan(action: .update)
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

    func execute(_ plan: HomebrewActionPlan) async throws -> HomebrewActionResult {
        guard !mutationInProgress else {
            throw HomebrewClientError.invalidPlan("已有 Homebrew 写操作正在执行")
        }
        guard plan.canExecute else {
            throw HomebrewClientError.invalidPlan("Tap 仍有关联的已安装软件包，不能移除")
        }
        guard Date().timeIntervalSince(plan.generatedAt) <= 300 else {
            throw HomebrewClientError.invalidPlan("操作计划已过期，请重新生成")
        }
        mutationInProgress = true
        defer { mutationInProgress = false }
        try validateExecutable()
        try await validateFreshness(of: plan)
        let arguments = try arguments(for: plan)
        var actionEnvironment = environment
        actionEnvironment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        if plan.action == .uninstallFormula || plan.action == .uninstallCask || plan.action == .zapCask {
            actionEnvironment["HOMEBREW_NO_AUTOREMOVE"] = "1"
            actionEnvironment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        }
        let output = try await run(
            arguments,
            environment: actionEnvironment,
            timeout: .seconds(1_800)
        )
        do {
            let snapshot = try await loadSnapshot()
            return HomebrewActionResult(
                plan: plan,
                command: output,
                snapshot: snapshot,
                postflightError: nil,
                remainingResidualPaths: remainingResidualPaths(from: plan)
            )
        } catch {
            return HomebrewActionResult(
                plan: plan,
                command: output,
                snapshot: nil,
                postflightError: error.localizedDescription,
                remainingResidualPaths: remainingResidualPaths(from: plan)
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
        stateFingerprint: String? = nil
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
            stateFingerprint: stateFingerprint
        )
    }

    private func validateFreshness(of plan: HomebrewActionPlan) async throws {
        switch plan.action {
        case .install:
            guard let target = plan.targets.first else {
                throw HomebrewClientError.invalidPlan("安装计划缺少目标")
            }
            let package = try await loadPackage(target)
            guard !package.isInstalled, packageFingerprint(package) == plan.stateFingerprint else {
                throw HomebrewClientError.invalidPlan("软件包状态已经变化，请重新生成安装计划")
            }
        case .upgrade:
            let snapshot = try await loadSnapshot()
            guard snapshot.sectionErrors[.outdated] == nil,
                  identitiesFingerprint(plan.targets) == plan.stateFingerprint
            else {
                throw HomebrewClientError.invalidPlan("升级状态已经变化，请刷新后重试")
            }
            let outdated = Set(snapshot.outdatedPackages.map(\.identity))
            guard plan.targets.allSatisfy(outdated.contains) else {
                throw HomebrewClientError.invalidPlan("升级目标已经变化，请重新生成计划")
            }
        case .removeTap:
            guard let tapName = plan.tapName else {
                throw HomebrewClientError.invalidPlan("Tap 操作缺少名称")
            }
            let current = try await planRemoveTap(tapName)
            guard current.associatedPackages == plan.associatedPackages, current.canExecute else {
                throw HomebrewClientError.invalidPlan("Tap 关联项目已经变化，请重新生成计划")
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
                throw HomebrewClientError.invalidPlan("卸载目标状态已经变化，请重新生成计划")
            }
        case .addTap:
            guard let tapName = plan.tapName else {
                throw HomebrewClientError.invalidPlan("Tap 操作缺少名称")
            }
            let snapshot = try await loadSnapshot()
            guard snapshot.sectionErrors[.taps] == nil,
                  !snapshot.taps.contains(where: { $0.name == tapName })
            else {
                throw HomebrewClientError.invalidPlan("Tap 状态已经变化，请重新生成计划")
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

    private func identitiesFingerprint(_ identities: [HomebrewPackageIdentity]) -> String {
        identities.map { "\($0.kind.rawValue):\($0.name)" }.sorted().joined(separator: "|")
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
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return nil }
        var total: Int64 = 0
        var visited = 0
        for case let itemURL as URL in enumerator {
            visited += 1
            if visited > 100_000 { return nil }
            guard let item = try? itemURL.resourceValues(forKeys: keys) else { continue }
            total += Int64(item.totalFileAllocatedSize ?? item.fileAllocatedSize ?? 0)
        }
        return total
    }

    private func remainingResidualPaths(from plan: HomebrewActionPlan) -> [HomebrewResidualPath] {
        plan.residualPaths.compactMap { residual in
            let url = URL(filePath: residual.path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return HomebrewResidualPath(
                path: residual.path,
                artifactKind: residual.artifactKind,
                estimatedBytes: allocatedSize(at: url)
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

private struct BrewInfoEnvelope: Decodable {
    let formulae: [BrewFormulaPayload]
    let casks: [BrewCaskPayload]
}

private struct BrewOutdatedEnvelope: Decodable {
    let formulae: [BrewOutdatedPayload]
    let casks: [BrewOutdatedPayload]

    var models: [HomebrewOutdatedPackage] {
        let formulas = formulae.compactMap { $0.model(kind: .formula) }
        let caskModels = casks.compactMap { $0.model(kind: .cask) }
        return (formulas + caskModels).sorted {
            if $0.identity.kind != $1.identity.kind {
                return $0.identity.kind.sortOrder < $1.identity.kind.sortOrder
            }
            return $0.identity.name.localizedStandardCompare($1.identity.name) == .orderedAscending
        }
    }
}

private struct BrewOutdatedPayload: Decodable {
    let name: String?
    let fullName: String?
    let token: String?
    let installedVersions: [String]
    let currentVersion: String?

    enum CodingKeys: String, CodingKey {
        case name
        case fullName = "full_name"
        case token
        case installedVersions = "installed_versions"
        case currentVersion = "current_version"
    }

    func model(kind: HomebrewPackageKind) -> HomebrewOutdatedPackage? {
        guard let identifier = fullName ?? name ?? token else { return nil }
        return HomebrewOutdatedPackage(
            identity: HomebrewPackageIdentity(name: identifier, kind: kind),
            installedVersions: installedVersions,
            currentVersion: currentVersion
        )
    }
}

private struct BrewFormulaPayload: Decodable {
    struct Versions: Decodable {
        let stable: String?
        let head: String?
    }

    struct Installed: Decodable {
        let version: String
    }

    let name: String
    let fullName: String
    let tap: String?
    let description: String?
    let homepage: String?
    let versions: Versions
    let installed: [Installed]
    let dependencies: [String]
    let pinned: Bool
    let deprecated: Bool
    let disabled: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case fullName = "full_name"
        case tap
        case description = "desc"
        case homepage
        case versions
        case installed
        case dependencies
        case pinned
        case deprecated
        case disabled
    }

    var model: HomebrewPackage {
        HomebrewPackage(
            identity: HomebrewPackageIdentity(name: fullName, kind: .formula),
            displayName: name,
            description: description,
            homepage: homepage,
            installedVersions: installed.map(\.version),
            currentVersion: versions.stable ?? versions.head,
            tap: tap,
            dependencies: dependencies,
            pinned: pinned,
            deprecated: deprecated,
            disabled: disabled,
            artifacts: []
        )
    }
}

private struct BrewCaskPayload: Decodable {
    let token: String
    let fullToken: String
    let tap: String?
    let names: FlexibleStringList
    let description: String?
    let homepage: String?
    let version: String?
    let installed: FlexibleStringList?
    let outdated: Bool
    let artifacts: [DynamicObject]

    enum CodingKeys: String, CodingKey {
        case token
        case fullToken = "full_token"
        case tap
        case names = "name"
        case description = "desc"
        case homepage
        case version
        case installed
        case outdated
        case artifacts
    }

    var model: HomebrewPackage {
        let resolvedTap = tap ?? Self.tapName(from: fullToken, token: token)
        return HomebrewPackage(
            identity: HomebrewPackageIdentity(name: fullToken, kind: .cask),
            displayName: names.values.first ?? token,
            description: description,
            homepage: homepage,
            installedVersions: installed?.values ?? [],
            currentVersion: version,
            tap: resolvedTap,
            dependencies: [],
            pinned: false,
            deprecated: false,
            disabled: false,
            artifacts: artifacts.flatMap(\.artifacts)
        )
    }

    private static func tapName(from fullToken: String, token: String) -> String? {
        guard fullToken != token else { return nil }
        let components = fullToken.split(separator: "/")
        guard components.count >= 3 else { return nil }
        return components.prefix(2).joined(separator: "/")
    }
}

private struct BrewTapPayload: Decodable {
    let name: String
    let path: String
    let remote: String?
    let official: Bool
    let trusted: Bool
    let formulaNames: [String]
    let caskTokens: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case remote
        case official
        case trusted
        case formulaNames = "formula_names"
        case caskTokens = "cask_tokens"
    }

    var model: HomebrewTap {
        HomebrewTap(
            name: name,
            remote: remote,
            path: path,
            official: official,
            trusted: trusted,
            formulaNames: formulaNames,
            caskTokens: caskTokens
        )
    }
}

private struct FlexibleStringList: Decodable {
    let values: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            values = []
        } else if let list = try? container.decode([String].self) {
            values = list
        } else {
            values = [try container.decode(String.self)]
        }
    }
}

private struct DynamicObject: Decodable {
    let values: [String: DynamicValue]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        values = try container.allKeys.reduce(into: [:]) { result, key in
            result[key.stringValue] = try container.decode(DynamicValue.self, forKey: key)
        }
    }

    var artifacts: [HomebrewCaskArtifact] {
        values.flatMap { key, value -> [HomebrewCaskArtifact] in
            if key == "zap", case .array(let entries) = value {
                return entries.flatMap { entry -> [HomebrewCaskArtifact] in
                    guard case .object(let object) = entry else { return [] }
                    return object.map { zapKey, zapValue in
                        HomebrewCaskArtifact(kind: zapKey, values: zapValue.strings, category: .zap)
                    }
                }
            }
            return [HomebrewCaskArtifact(kind: key, values: value.strings, category: .installed)]
        }
    }
}

private indirect enum DynamicValue: Decodable {
    case string(String)
    case array([DynamicValue])
    case object([String: DynamicValue])
    case scalar(String)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([DynamicValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: DynamicValue].self) {
            self = .object(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .scalar(String(value))
        } else if let value = try? container.decode(Double.self) {
            self = .scalar(String(value))
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    var strings: [String] {
        switch self {
        case .string(let value), .scalar(let value):
            [value]
        case .array(let values):
            values.flatMap(\.strings)
        case .object(let values):
            values.keys.sorted().flatMap { values[$0]?.strings ?? [] }
        case .null:
            []
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
