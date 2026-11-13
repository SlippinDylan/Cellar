import CryptoKit
import Foundation

actor NodeManagerClient {
    private let runner: ProcessRunner
    private let environmentResolver: NodeEnvironmentResolver
    private var registryConfirmations: [UUID: (environment: [String: String], fingerprint: String)] = [:]
    private var configurationConfirmations: [UUID: (environment: [String: String], fingerprint: String)] = [:]
    private var projectConfirmations: [UUID: (environment: [String: String], fingerprint: String, directory: NodeProjectDirectory)] = [:]
    private var logConfirmations: [UUID: NodeLogMaintenanceState] = [:]

    init(runner: ProcessRunner, environmentResolver: NodeEnvironmentResolver = NodeEnvironmentResolver()) {
        self.runner = runner
        self.environmentResolver = environmentResolver
    }

    func loadSnapshot(
        managerDirectory: URL,
        preferredNodeVersion: String? = nil,
        includingOutdated: Bool = true
    ) async throws -> NodeSnapshot {
        let environment = environmentResolver.environment(preferredNodeVersion: preferredNodeVersion)
        let summaryValue: NodeSummary = try await request(
            "summary", managerDirectory: managerDirectory, environment: environment
        )
        return try await loadSnapshot(managerDirectory: managerDirectory, preferredNodeVersion: preferredNodeVersion,
                                      environment: environment, summary: summaryValue, includingOutdated: includingOutdated)
    }

    private func loadSnapshot(
        managerDirectory: URL,
        preferredNodeVersion: String?,
        environment: [String: String],
        summary: NodeSummary,
        includingOutdated: Bool = true
    ) async throws -> NodeSnapshot {
        let inventoryValue: NodePackageInventory = try await request(
            "packages", managerDirectory: managerDirectory, environment: environment
        )
        let configurationValue: NodeConfiguration = try await request(
            "config", managerDirectory: managerDirectory, environment: environment
        )
        let statusResult: Result<NodeManagerStatus, Error> = await captureNodeRequest {
            try await self.request("status", managerDirectory: managerDirectory, environment: environment)
        }
        let logsResult: Result<[String], Error> = await captureNodeRequest {
            try await self.request(
                "logs", arguments: ["20"], managerDirectory: managerDirectory, environment: environment
            )
        }
        let outdatedResult: Result<[String: OutdatedPackage], Error>
        if includingOutdated {
            do {
                let outdated: [String: OutdatedPackage] = try await request(
                    "outdated", managerDirectory: managerDirectory, environment: environment
                )
                outdatedResult = .success(outdated)
            } catch {
                outdatedResult = .failure(error)
            }
        } else { outdatedResult = .success([:]) }
        let outdatedValue = (try? outdatedResult.get()) ?? [:]
        let packages: [NodePackageRow] = (inventoryValue.dependencies ?? [:]).map { name, package in
            let available = outdatedValue[name]
            return NodePackageRow(
                name: name,
                installedVersion: package.version ?? "未知",
                wantedVersion: available?.wanted,
                latestVersion: available?.latest
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        try Task.checkCancellation()
        let outdatedError = outdatedResult.failure?.localizedDescription
        return NodeSnapshot(
            summary: summary,
            configuration: configurationValue,
            packages: packages,
            installations: environmentResolver.installations(preferredNodeVersion: preferredNodeVersion),
            managerStatus: try? statusResult.get(),
            logs: (try? logsResult.get()) ?? [],
            outdatedError: outdatedError,
            maintenanceError: [statusResult.failure, logsResult.failure]
                .compactMap { $0?.localizedDescription }
                .joined(separator: "；")
                .nilIfBlank
        )
    }

    func loadOutdatedPackages(managerDirectory: URL, summary: NodeSummary) async throws -> [String: OutdatedPackage] {
        guard summary.nodePath.hasPrefix("/"), summary.npmPath.hasPrefix("/") else {
            throw BridgeError.managerFailure(code: "node-environment-changed", detail: nil)
        }
        let nodeExecutable = URL(filePath: summary.nodePath)
        let npmExecutable = URL(filePath: summary.npmPath)
        guard FileManager.default.isExecutableFile(atPath: nodeExecutable.path),
              FileManager.default.isExecutableFile(atPath: npmExecutable.path)
        else { throw BridgeError.managerFailure(code: "node-environment-changed", detail: nil) }
        let environment = environmentResolver.environment(nodeExecutable: nodeExecutable, npmExecutable: npmExecutable)
        let current: NodeSummary = try await request("summary", managerDirectory: managerDirectory, environment: environment)
        guard current.nodePath == summary.nodePath, current.npmPath == summary.npmPath,
              current.nodeVersion == summary.nodeVersion, current.npmVersion == summary.npmVersion,
              current.globalPrefix == summary.globalPrefix, current.globalRoot == summary.globalRoot
        else { throw BridgeError.managerFailure(code: "node-environment-changed", detail: nil) }
        return try await request("outdated", managerDirectory: managerDirectory, environment: environment)
    }

    func plan(
        _ request: NodeActionRequest,
        managerDirectory: URL,
        preferredNodeVersion: String? = nil
    ) async throws -> NodeActionPlan {
        let environment = environmentResolver.environment(preferredNodeVersion: preferredNodeVersion)
        if request.action == .cleanup, request.subject == NodeMaintenanceAction.logs.rawValue {
            guard request.value == "100" else { throw BridgeError.managerFailure(code: "invalid-log-retention", detail: nil) }
            let state = try NodeLogMaintenanceState.read(managerDirectory: managerDirectory)
            let plan = try await self.plan(request, managerDirectory: managerDirectory, environment: environment)
            guard state == (try NodeLogMaintenanceState.read(managerDirectory: managerDirectory)) else { throw BridgeError.managerFailure(code: "plan-stale", detail: nil) }
            logConfirmations[plan.id] = state
            return NodeActionPlan(id: plan.id, request: request, payload: plan.payload, generatedAt: plan.generatedAt, maintenanceCandidates: state.candidates)
        }
        if request.action.isRegistryConfiguration {
            try validateRegistryRequest(request)
            let fingerprint = try registryFingerprint(environment: environment, managerDirectory: managerDirectory)
            let plan = try await plan(request, managerDirectory: managerDirectory, environment: environment)
            guard fingerprint == (try registryFingerprint(environment: environment, managerDirectory: managerDirectory)),
                  plan.payload.effectiveRegistry != nil else { throw BridgeError.managerFailure(code: "registry-state-unavailable", detail: nil) }
            registryConfirmations[plan.id] = (environment, fingerprint)
            return plan
        }
        if request.action == .writeProjectNVMRC {
            let directory = try NodeProjectDirectory.read(selectedPath: request.subject)
            let canonicalRequest = NodeActionRequest(action: request.action, subject: directory.canonicalURL.path, value: request.value)
            let fingerprint = try configurationFingerprint(canonicalRequest, environment: environment)
            let plan = try await self.plan(canonicalRequest, managerDirectory: managerDirectory, environment: environment)
            try directory.requireUnchanged(selectedPath: request.subject)
            guard fingerprint == (try configurationFingerprint(canonicalRequest, environment: environment)) else { throw BridgeError.managerFailure(code: "plan-stale", detail: nil) }
            projectConfirmations[plan.id] = (environment, fingerprint, directory)
            return NodeActionPlan(id: plan.id, request: request, payload: plan.payload, generatedAt: plan.generatedAt)
        }
        if [.setDefaultNode, .uninstallNode].contains(request.action) {
            let fingerprint = try configurationFingerprint(request, environment: environment)
            let plan = try await self.plan(request, managerDirectory: managerDirectory, environment: environment)
            guard fingerprint == (try configurationFingerprint(request, environment: environment)) else { throw BridgeError.managerFailure(code: "plan-stale", detail: nil) }
            configurationConfirmations[plan.id] = (environment, fingerprint)
            return plan
        }
        return try await plan(request, managerDirectory: managerDirectory, environment: environment)
    }

    private func plan(
        _ request: NodeActionRequest,
        managerDirectory: URL,
        environment: [String: String]
    ) async throws -> NodeActionPlan {
        let payload: NodeActionPlanPayload = try await self.request(
            "plan",
            arguments: planArguments(for: request),
            managerDirectory: managerDirectory,
            environment: environment
        )
        guard payload.action == request.action.rawValue else {
            throw BridgeError.invalidOutput("Node Manager 返回了不匹配的操作计划")
        }
        return NodeActionPlan(id: UUID(), request: request, payload: payload, generatedAt: Date())
    }

    func execute(
        _ plan: NodeActionPlan,
        managerDirectory: URL,
        preferredNodeVersion: String? = nil
    ) async throws -> NodeOperationResult {
        let environment = environmentResolver.environment(preferredNodeVersion: preferredNodeVersion)
        if plan.request.action == .writeProjectNVMRC {
            return try await executeProject(plan, managerDirectory: managerDirectory, environment: environment)
        }
        if plan.request.action == .cleanup, plan.request.subject == NodeMaintenanceAction.logs.rawValue {
            guard let state = logConfirmations.removeValue(forKey: plan.id), state == (try NodeLogMaintenanceState.read(managerDirectory: managerDirectory)) else { throw BridgeError.managerFailure(code: "plan-stale", detail: nil) }
        }
        if [.setDefaultNode, .uninstallNode].contains(plan.request.action) {
            guard let baseline = configurationConfirmations.removeValue(forKey: plan.id), baseline.environment == environment,
                  baseline.fingerprint == (try configurationFingerprint(plan.request, environment: environment)) else { throw BridgeError.managerFailure(code: "plan-stale", detail: nil) }
            let current = try await self.plan(plan.request, managerDirectory: managerDirectory, environment: environment)
            guard current.canExecute, current.payload.normalizedVersion == plan.payload.normalizedVersion,
                  current.payload.currentVersion == plan.payload.currentVersion, current.payload.defaultVersion == plan.payload.defaultVersion,
                  current.payload.versionDir == plan.payload.versionDir, current.payload.globalPackageSummary == plan.payload.globalPackageSummary,
                  current.payload.currentNvmrc == plan.payload.currentNvmrc, current.payload.enginesNode == plan.payload.enginesNode,
                  baseline.fingerprint == (try configurationFingerprint(plan.request, environment: environment)) else { throw BridgeError.managerFailure(code: "plan-stale", detail: nil) }
        }
        if plan.request.action.isRegistryConfiguration {
            guard let baseline = registryConfirmations.removeValue(forKey: plan.id), baseline.environment == environment,
                  baseline.fingerprint == (try registryFingerprint(environment: environment, managerDirectory: managerDirectory))
            else { throw BridgeError.managerFailure(code: "registry-state-changed", detail: nil) }
            let current = try await self.plan(plan.request, managerDirectory: managerDirectory, environment: environment)
            guard current.payload.effectiveRegistry == plan.payload.effectiveRegistry,
                  current.payload.userRegistry == plan.payload.userRegistry,
                  current.payload.projectRegistry == plan.payload.projectRegistry,
                  current.payload.globalRegistry == plan.payload.globalRegistry,
                  baseline.fingerprint == (try registryFingerprint(environment: environment, managerDirectory: managerDirectory))
            else { throw BridgeError.managerFailure(code: "registry-state-changed", detail: nil) }
        }
        return try await execute(plan, managerDirectory: managerDirectory, environment: environment)
    }

    private func validateRegistryRequest(_ request: NodeActionRequest) throws {
        switch request.action {
        case .setRegistry:
            guard SourceConfiguration.registryURL(request.subject) != nil else { throw CatalogSourceError.invalidURL }
        case .setScopeRegistry:
            guard SourceConfiguration.validScope(request.subject), let value = request.value,
                  SourceConfiguration.registryURL(value) != nil else { throw CatalogSourceError.invalidURL }
        case .deleteScopeRegistry:
            guard SourceConfiguration.validScope(request.subject) else { throw CatalogSourceError.invalidURL }
        default: break
        }
    }

    private func executeProject(_ plan: NodeActionPlan, managerDirectory: URL, environment: [String: String]) async throws -> NodeOperationResult {
        guard let baseline = projectConfirmations.removeValue(forKey: plan.id), baseline.environment == environment else {
            throw BridgeError.managerFailure(code: "project-changed", detail: nil)
        }
        try baseline.directory.requireUnchanged(selectedPath: plan.request.subject)
        let request = NodeActionRequest(action: .writeProjectNVMRC, subject: baseline.directory.canonicalURL.path, value: plan.request.value)
        guard baseline.fingerprint == (try configurationFingerprint(request, environment: environment)) else { throw BridgeError.managerFailure(code: "plan-stale", detail: nil) }
        let current = try await self.plan(request, managerDirectory: managerDirectory, environment: environment)
        guard current.canExecute, current.payload.currentNvmrc == plan.payload.currentNvmrc,
              current.payload.enginesNode == plan.payload.enginesNode,
              baseline.fingerprint == (try configurationFingerprint(request, environment: environment)) else { throw BridgeError.managerFailure(code: "plan-stale", detail: nil) }
        // Keep the original confirmation/expiry; only its execution path becomes canonical.
        let execution = NodeActionPlan(id: plan.id, request: request, payload: plan.payload, generatedAt: plan.generatedAt)
        let result = try await execute(execution, managerDirectory: managerDirectory, environment: environment,
                                       project: (baseline.directory, plan.request.subject))
        guard result.exitCode == 0, result.status == "ok" else { return result }
        var detail: String?
        do {
            try baseline.directory.requireUnchanged(selectedPath: plan.request.subject)
            let written = try NodeConfigurationFile.read(at: baseline.directory.canonicalURL.appending(path: ".nvmrc"), maximumBytes: 4096)
            guard let version = plan.request.value, written?.contents == Data((version + "\n").utf8),
                  result.action == request.action.rawValue, result.subject == request.subject else {
                throw BridgeError.managerFailure(code: "project-verification-unavailable", detail: nil)
            }
            try baseline.directory.requireUnchanged(selectedPath: plan.request.subject)
        } catch BridgeError.managerFailure(let code, _) {
            detail = code == "project-changed" ? code : "project-verification-unavailable"
        } catch {
            detail = "project-verification-unavailable"
        }
        return NodeOperationResult(operationId: result.operationId, action: result.action, subject: plan.request.subject,
                                   exitCode: result.exitCode, status: detail == nil ? result.status : "unknown", logFile: result.logFile, detail: detail ?? result.detail, residues: result.residues)
    }

    private func registryFingerprint(environment: [String: String], managerDirectory: URL) throws -> String {
        guard let home = environment["HOME"] else { throw BridgeError.managerFailure(code: "registry-home-unavailable", detail: nil) }
        var files = [URL(filePath: home).appending(path: ".npmrc"), managerDirectory.appending(path: ".npmrc")]
        if let bin = environment["PATH"]?.split(separator: ":").first, bin.hasPrefix(home + "/.nvm/versions/node/") {
            files.append(URL(filePath: String(bin)).deletingLastPathComponent().appending(path: "etc/npmrc"))
        }
        var material = Data()
        try appendConfigurationFile(URL(filePath: home).appending(path: ".nvm/alias/default"), to: &material)
        var visited = Set<String>()
        while !files.isEmpty {
            let file = files.removeFirst().standardizedFileURL
            guard visited.insert(file.path).inserted else { continue }
            guard visited.count <= 16 else { throw BridgeError.managerFailure(code: "registry-configuration-limit", detail: nil) }
            guard let snapshot = try appendConfigurationFile(file, to: &material, maximumBytes: 65_536) else { continue }
            guard let contents = String(data: snapshot.contents, encoding: .utf8) else { throw BridgeError.managerFailure(code: "registry-configuration-encoding", detail: nil) }
            for line in contents.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, ["userconfig", "globalconfig", "prefix"].contains(parts[0].lowercased()) else { continue }
                let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    .replacingOccurrences(of: "${HOME}", with: home)
                guard value.hasPrefix("/"), !value.contains("${") else { throw BridgeError.managerFailure(code: "registry-configuration-path", detail: nil) }
                let reference = URL(filePath: value)
                files.append(parts[0].lowercased() == "prefix" ? reference.appending(path: "etc/npmrc") : reference)
            }
        }
        return SHA256.hash(data: material).description
    }

    private func configurationFingerprint(_ request: NodeActionRequest, environment: [String: String]) throws -> String {
        guard let home = environment["HOME"] else { throw BridgeError.managerFailure(code: "node-home-unavailable", detail: nil) }
        var files = [URL(filePath: home).appending(path: ".nvm/alias/default")]
        if request.action == .writeProjectNVMRC {
            let project = URL(filePath: request.subject)
            files += [project.appending(path: ".nvmrc"), project.appending(path: "package.json")]
        }
        var material = Data()
        for file in files {
            try appendConfigurationFile(file, to: &material)
        }
        return SHA256.hash(data: material).description
    }

    @discardableResult
    private func appendConfigurationFile(_ file: URL, to material: inout Data, maximumBytes: Int? = nil) throws -> NodeConfigurationFile? {
        let cap = maximumBytes ?? (file.lastPathComponent == "package.json" ? 1_048_576 : file.lastPathComponent == ".npmrc" ? 65_536 : 4_096)
        material.append(Data(file.standardizedFileURL.path.utf8))
        material.append(0)
        let snapshot = try NodeConfigurationFile.read(at: file, maximumBytes: cap)
        if let snapshot {
            material.append(Data(snapshot.identity.utf8))
            material.append(0)
            material.append(snapshot.contents)
        } else { material.append(Data("missing".utf8)) }
        material.append(0)
        return snapshot
    }

    private func execute(
        _ plan: NodeActionPlan,
        managerDirectory: URL,
        environment: [String: String],
        project: (directory: NodeProjectDirectory, selectedPath: String)? = nil
    ) async throws -> NodeOperationResult {
        guard plan.canExecute else {
            throw BridgeError.managerFailure(
                code: plan.payload.blockedReason ?? "plan-not-executable",
                detail: "Node 操作计划当前不可执行"
            )
        }
        guard Date().timeIntervalSince(plan.generatedAt) <= 300 else {
            throw BridgeError.managerFailure(code: "plan-expired", detail: "Node 操作计划已过期，请重新生成")
        }

        if plan.request.action == .writeProjectNVMRC {
            guard let project else { preconditionFailure("Project execution requires its confirmed directory") }
            try project.directory.requireUnchanged(selectedPath: project.selectedPath)
        }
        var environment = environment
        environment["NODE_MANAGER_ALLOW_JSON_EXECUTE"] = "1"
        if plan.request.action == .writeProjectNVMRC {
            environment["NODE_MANAGER_ALLOW_PROJECT_WRITE"] = "1"
        }
        return try await request(
            "execute",
            arguments: try executeArguments(for: plan),
            managerDirectory: managerDirectory,
            environment: environment,
            timeout: .seconds(1_800)
        )
    }

    func planPackage(_ identity: NPMPackageIdentity, action: NodeAction, managerDirectory: URL) async throws -> NodeActionPlan {
        guard action == .installPackage || action == .updatePackage || action == .uninstallPackage else {
            throw BridgeError.managerFailure(code: "not-package-action", detail: nil)
        }
        let validated = try await validatedPackageEnvironment(identity.environment, managerDirectory: managerDirectory)
        let registry = action != .uninstallPackage ? try await packageRegistry(identity.name, summary: validated.summary, environment: validated.environment, managerDirectory: managerDirectory) : nil
        let plan = try await plan(.init(action: action, subject: identity.name), managerDirectory: managerDirectory,
                                  environment: validated.environment)
        if action != .uninstallPackage {
            let final = try await validatedPackageEnvironment(identity.environment, managerDirectory: managerDirectory)
            guard try packageDestination(validated.summary) == packageDestination(final.summary),
                  registry == (try await packageRegistry(identity.name, summary: final.summary, environment: final.environment, managerDirectory: managerDirectory))
            else { throw BridgeError.managerFailure(code: action == .updatePackage ? "npm-update-state-changed" : "npm-install-state-changed", detail: nil) }
            if action == .updatePackage {
                guard plan.payload.packageName == identity.name,
                      SemanticVersionStatus(current: plan.payload.installedVersion, available: plan.payload.targetVersion) == .behind
                else { throw BridgeError.managerFailure(code: "npm-update-not-behind", detail: nil) }
            }
        }
        return NodeActionPlan(id: plan.id, request: plan.request, payload: plan.payload, generatedAt: plan.generatedAt,
                              confirmedPackageDestination: try packageDestination(validated.summary),
                              confirmedInstallRegistry: registry)
    }

    func renewBatchPackagePlan(_ confirmed: NodeActionPlan, environment: NodeEnvironmentContext, managerDirectory: URL) async throws -> NodeActionPlan? {
        guard confirmed.request.action == .installPackage || confirmed.request.action == .updatePackage else {
            throw BridgeError.managerFailure(code: "not-package-action", detail: nil)
        }
        let changed = BridgeError.managerFailure(code: "npm-install-state-changed", detail: nil)
        guard confirmed.exactInstallSpec != nil || confirmed.exactUpdateSpec != nil else { throw changed }
        let validated = try await validatedPackageEnvironment(environment, managerDirectory: managerDirectory)
        guard try packageDestination(validated.summary) == confirmed.confirmedPackageDestination,
              confirmed.confirmedInstallRegistry == (try await packageRegistry(confirmed.request.subject, summary: validated.summary, environment: validated.environment, managerDirectory: managerDirectory))
        else { throw changed }
        // Read the same request so changes to a tag or latest cannot silently change the confirmed version.
        let current = try await plan(confirmed.request, managerDirectory: managerDirectory, environment: validated.environment)
        guard current.payload.packageName == confirmed.payload.packageName,
              current.payload.targetVersion == confirmed.payload.targetVersion,
              let target = confirmed.payload.targetVersion else { throw changed }
        let final = try await validatedPackageEnvironment(environment, managerDirectory: managerDirectory)
        guard try packageDestination(final.summary) == confirmed.confirmedPackageDestination,
              confirmed.confirmedInstallRegistry == (try await packageRegistry(confirmed.request.subject, summary: final.summary, environment: final.environment, managerDirectory: managerDirectory))
        else { throw changed }
        if current.payload.installedVersion == target { return nil }
        guard current.canExecute, current.payload.installedVersion == confirmed.payload.installedVersion else { throw changed }
        return NodeActionPlan(id: current.id, request: current.request, payload: current.payload, generatedAt: current.generatedAt,
                              confirmedPackageDestination: confirmed.confirmedPackageDestination, confirmedInstallRegistry: confirmed.confirmedInstallRegistry)
    }

    func executePackage(_ plan: NodeActionPlan, environment: NodeEnvironmentContext, managerDirectory: URL) async throws -> NodeOperationResult {
        guard plan.request.action == .installPackage || plan.request.action == .updatePackage || plan.request.action == .uninstallPackage else {
            throw BridgeError.managerFailure(code: "not-package-action", detail: nil)
        }
        let validated = try await validatedPackageEnvironment(environment, managerDirectory: managerDirectory)
        if plan.request.action == .uninstallPackage {
            let currentPlan = try await self.plan(plan.request, managerDirectory: managerDirectory, environment: validated.environment)
            guard plan.payload.packageName == plan.request.subject, plan.payload.installedVersion?.isEmpty == false,
                  currentPlan.canExecute, currentPlan.payload.packageName == plan.payload.packageName,
                  currentPlan.payload.installedVersion == plan.payload.installedVersion
            else { throw BridgeError.managerFailure(code: "npm-uninstall-state-changed", detail: nil) }
            // Re-read the destination after planning, immediately before opening the write gate.
            let finalEnvironment = try await validatedPackageEnvironment(environment, managerDirectory: managerDirectory)
            guard let confirmed = plan.confirmedPackageDestination,
                  confirmed == (try packageDestination(finalEnvironment.summary))
            else { throw BridgeError.managerFailure(code: "npm-uninstall-state-changed", detail: nil) }
            return try await execute(plan, managerDirectory: managerDirectory, environment: finalEnvironment.environment)
        }
        if plan.request.action == .installPackage || plan.request.action == .updatePackage {
            let changedCode = plan.request.action == .updatePackage ? "npm-update-state-changed" : "npm-install-state-changed"
            guard let confirmed = plan.confirmedPackageDestination,
                  confirmed == (try packageDestination(validated.summary)),
                  plan.confirmedInstallRegistry == (try await packageRegistry(plan.request.subject, summary: validated.summary, environment: validated.environment, managerDirectory: managerDirectory))
            else { throw BridgeError.managerFailure(code: changedCode, detail: nil) }
            let currentPlan = try await self.plan(plan.request, managerDirectory: managerDirectory, environment: validated.environment)
            guard currentPlan.canExecute,
                  currentPlan.payload.packageName == plan.payload.packageName,
                  currentPlan.payload.targetVersion == plan.payload.targetVersion,
                  currentPlan.payload.installedVersion == plan.payload.installedVersion
            else { throw BridgeError.managerFailure(code: changedCode, detail: nil) }
            let finalEnvironment = try await validatedPackageEnvironment(environment, managerDirectory: managerDirectory)
            guard confirmed == (try packageDestination(finalEnvironment.summary)),
                  plan.confirmedInstallRegistry == (try await packageRegistry(plan.request.subject, summary: finalEnvironment.summary, environment: finalEnvironment.environment, managerDirectory: managerDirectory))
            else { throw BridgeError.managerFailure(code: changedCode, detail: nil) }
            let result = try await execute(plan, managerDirectory: managerDirectory, environment: finalEnvironment.environment)
            return await verifyPackageWrite(result, plan: plan, context: environment, managerDirectory: managerDirectory)
        }
        return try await execute(plan, managerDirectory: managerDirectory, environment: validated.environment)
    }

    private func verifyPackageWrite(_ result: NodeOperationResult, plan: NodeActionPlan, context: NodeEnvironmentContext,
                                     managerDirectory: URL) async -> NodeOperationResult {
        var status = result.status
        var detail = result.detail
        let action = plan.request.action == .updatePackage ? "update" : "install"
        guard let packageName = plan.payload.packageName else { preconditionFailure("Package execution requires a validated exact target") }
        if result.action != NodeAction.installPackage.rawValue || result.subject != packageName {
            status = "unknown"
            detail = "\(action)-result-unavailable"
        } else if result.exitCode == 0 && result.status == "ok" {
            do {
                let current = try await validatedPackageEnvironment(context, managerDirectory: managerDirectory, requireMatchingNPMVersion: false)
                guard try packageDestination(current.summary) == plan.confirmedPackageDestination else {
                    throw BridgeError.managerFailure(code: "npm-update-destination-changed", detail: nil)
                }
                let inventory: NodePackageInventory = try await request("packages", managerDirectory: managerDirectory, environment: current.environment)
                if inventory.dependencies?[packageName]?.version != plan.payload.targetVersion {
                    status = "failed"
                    detail = "\(action)-target-mismatch"
                }
            } catch {
                status = "unknown"
                detail = "\(action)-verification-unavailable"
            }
        }
        return NodeOperationResult(operationId: result.operationId, action: plan.request.action.rawValue, subject: plan.request.subject,
                                   exitCode: result.exitCode, status: status, logFile: result.logFile, detail: detail, residues: result.residues)
    }

    private func packageDestination(_ summary: NodeSummary) throws -> NodePackageDestination {
        guard [summary.nodePath, summary.npmPath, summary.globalPrefix, summary.globalRoot].allSatisfy({ $0.hasPrefix("/") })
        else { throw BridgeError.invalidOutput("npm package destination must use absolute paths") }
        func canonical(_ path: String) -> String {
            URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
        return NodePackageDestination(nodeExecutable: canonical(summary.nodePath), npmExecutable: canonical(summary.npmPath),
                                      globalPrefix: canonical(summary.globalPrefix), globalRoot: canonical(summary.globalRoot))
    }

    func effectivePackageRegistry(_ specOrQuery: String, environment: NodeEnvironmentContext, managerDirectory: URL) async throws -> URL {
        let validated = try await validatedPackageEnvironment(environment, managerDirectory: managerDirectory)
        return try await packageRegistry(specOrQuery, summary: validated.summary, environment: validated.environment, managerDirectory: managerDirectory)
    }

    func scopeRegistryLayers(_ scope: String, environment context: NodeEnvironmentContext, managerDirectory: URL) async throws -> NPMRegistryLayers {
        guard SourceConfiguration.validScope(scope) else { throw CatalogSourceError.invalidURL }
        let validated = try await validatedPackageEnvironment(context, managerDirectory: managerDirectory)
        let payload: NodeActionPlanPayload = try await request("plan", arguments: [NodeAction.deleteScopeRegistry.rawValue, scope],
                                                             managerDirectory: managerDirectory, environment: validated.environment)
        guard let effective = payload.effectiveRegistry, let user = payload.userRegistry,
              let project = payload.projectRegistry, let global = payload.globalRegistry else { throw BridgeError.invalidOutput("Registry layers unavailable") }
        return .init(effective: effective, user: user, project: project, global: global)
    }

    private func packageRegistry(_ specOrQuery: String, summary: NodeSummary, environment: [String: String], managerDirectory: URL) async throws -> URL {
        var value = summary.registry
        if let scope = try NPMRegistryClient.packageScope(specOrQuery) {
            // Cellar-owned typed read; the frozen Manager schema does not expose scoped configuration.
            let result = try await runner.run(ProcessRequest(executableURL: URL(filePath: summary.npmPath),
                                                            arguments: ["config", "get", "\(scope):registry"], environment: environment,
                                                            currentDirectoryURL: managerDirectory, timeout: .seconds(20)))
            guard result.terminationStatus == 0, !result.standardOutputWasTruncated, !result.standardErrorWasTruncated else { throw CatalogSourceError.invalidResponse }
            let configured = result.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
            if configured != "undefined", configured != "null" { value = configured }
        }
        guard let registryURL = URL(string: value) else { throw CatalogSourceError.invalidURL }
        return try NPMRegistryClient(registryURL: registryURL).registryURL
    }

    func planRuntimeUninstall(_ identity: NodeRuntimeIdentity, managerDirectory: URL) async throws -> NodeActionPlan {
        let validated = try await validatedPackageEnvironment(identity.environment, managerDirectory: managerDirectory)
        let plan = try await plan(.init(action: .uninstallNode, subject: identity.version), managerDirectory: managerDirectory,
                                  environment: validated.environment)
        if plan.canExecute {
            guard plan.payload.normalizedVersion == identity.version, plan.payload.versionDirExists == true,
                  plan.payload.versionDir?.hasPrefix("/") == true, plan.payload.defaultStatus == "resolved",
                  plan.payload.currentVersion?.isEmpty == false, plan.payload.defaultVersion?.isEmpty == false,
                  plan.payload.globalPackageSummary?.isEmpty == false
            else { throw BridgeError.invalidOutput("Node runtime uninstall state is incomplete") }
        }
        return plan
    }

    func executeRuntimeUninstall(_ plan: NodeActionPlan, environment: NodeEnvironmentContext, managerDirectory: URL) async throws -> NodeOperationResult {
        guard plan.request.action == .uninstallNode else {
            throw BridgeError.managerFailure(code: "not-runtime-uninstall", detail: nil)
        }
        let validated = try await validatedPackageEnvironment(environment, managerDirectory: managerDirectory)
        let currentPlan = try await self.plan(plan.request, managerDirectory: managerDirectory, environment: validated.environment)
        let before = plan.payload
        let current = currentPlan.payload
        guard currentPlan.canExecute, current.protectedByCurrent != true, current.protectedByDefault != true,
              current.normalizedVersion == before.normalizedVersion,
              current.currentVersion == before.currentVersion, current.defaultVersion == before.defaultVersion,
              current.defaultStatus == before.defaultStatus, current.versionDir == before.versionDir,
              current.versionDirExists == before.versionDirExists,
              current.globalPackageSummary == before.globalPackageSummary
        else { throw BridgeError.managerFailure(code: "node-uninstall-state-changed", detail: nil) }
        return try await execute(plan, managerDirectory: managerDirectory, environment: validated.environment)
    }

    private func validatedPackageEnvironment(
        _ context: NodeEnvironmentContext,
        managerDirectory: URL,
        requireMatchingNPMVersion: Bool = true
    ) async throws -> (environment: [String: String], summary: NodeSummary) {
        let installation = try requirePackageInstallation(context)
        let installationURL = URL(filePath: installation.directory, directoryHint: .isDirectory).resolvingSymlinksInPath()
        let bin = installationURL.appending(path: "bin", directoryHint: .isDirectory)
        var environment = environmentResolver.environment(preferredNodeVersion: context.nodeVersion)
        // Other provider directories must not supply node/npm if this installation disappears.
        environment["PATH"] = [bin.path, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        let summary: NodeSummary = try await request("summary", managerDirectory: managerDirectory, environment: environment)
        guard summary.nodeVersion == context.nodeVersion,
              !requireMatchingNPMVersion || summary.npmVersion == context.npmVersion
        else {
            throw BridgeError.managerFailure(code: "node-environment-changed", detail: nil)
        }
        if context.identifier.hasPrefix("/") {
            guard URL(filePath: context.identifier).resolvingSymlinksInPath().path
                    == URL(filePath: summary.nodePath).resolvingSymlinksInPath().path
            else { throw BridgeError.managerFailure(code: "node-environment-changed", detail: nil) }
        }
        try validatePackageEntries(summary, installationURL: installationURL)
        return (environment, summary)
    }

    func loadPackageSnapshot(_ context: NodeEnvironmentContext, managerDirectory: URL) async throws -> NodeSnapshot {
        let validated = try await validatedPackageEnvironment(context, managerDirectory: managerDirectory, requireMatchingNPMVersion: false)
        return try await loadSnapshot(managerDirectory: managerDirectory, preferredNodeVersion: context.nodeVersion,
                                      environment: validated.environment, summary: validated.summary)
    }

    private func requirePackageInstallation(_ context: NodeEnvironmentContext) throws -> NodeInstallation {
        let installations = environmentResolver.installations(preferredNodeVersion: context.nodeVersion)
        guard let installation = installations.first(where: { $0.version == context.nodeVersion }) else {
            throw BridgeError.managerFailure(code: "node-environment-changed", detail: nil)
        }
        return installation
    }

    private func validatePackageEntries(_ summary: NodeSummary, installationURL: URL) throws {
        let bin = installationURL.appending(path: "bin", directoryHint: .isDirectory)
        for (name, actualPath) in [("node", summary.nodePath), ("npm", summary.npmPath)] {
            let entry = bin.appending(path: name)
            let resolvedEntry = entry.resolvingSymlinksInPath()
            guard actualPath.hasPrefix("/"),
                  FileManager.default.isExecutableFile(atPath: entry.path),
                  resolvedEntry.path.hasPrefix(installationURL.path + "/"),
                  URL(filePath: actualPath).resolvingSymlinksInPath().path == resolvedEntry.path
            else {
                throw BridgeError.managerFailure(code: "node-environment-changed", detail: nil)
            }
        }
    }

    func request<Payload: Decodable & Sendable>(
        _ command: String,
        arguments: [String] = [],
        managerDirectory: URL,
        environment: [String: String],
        timeout: Duration? = .seconds(300)
    ) async throws -> Payload {
        let mainScript = managerDirectory.appending(path: "main.sh")
        guard FileManager.default.isReadableFile(atPath: mainScript.path) else {
            throw BridgeError.executableNotFound(mainScript.path)
        }

        let result = try await runner.run(ProcessRequest(
            executableURL: URL(filePath: "/bin/bash"),
            arguments: [mainScript.path, "--json", command] + arguments,
            environment: environment,
            currentDirectoryURL: managerDirectory,
            timeout: timeout
        ))
        let decoder = JSONDecoder()
        let envelope: ManagerEnvelope<Payload>
        do {
            envelope = try decoder.decode(ManagerEnvelope<Payload>.self, from: result.standardOutput)
        } catch {
            let diagnostic = result.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BridgeError.invalidOutput(diagnostic.isEmpty ? error.localizedDescription : diagnostic)
        }

        guard envelope.schemaVersion == 1 else {
            throw BridgeError.unsupportedSchema(envelope.schemaVersion)
        }
        guard result.terminationStatus == 0, envelope.ok, let payload = envelope.data else {
            let managerError = envelope.error
            let detail = managerError?.message ?? managerError?.stderr ?? result.errorText.nilIfBlank
            throw BridgeError.managerFailure(code: managerError?.code ?? "exit-\(result.terminationStatus)", detail: detail)
        }
        return payload
    }

    private func planArguments(for request: NodeActionRequest) -> [String] {
        var arguments = [request.action.rawValue]
        if !request.subject.isEmpty || request.value != nil {
            arguments.append(request.subject)
        }
        if let value = request.value {
            arguments.append(value)
        }
        return arguments
    }

    private func executeArguments(for plan: NodeActionPlan) throws -> [String] {
        if plan.request.action == .installPackage {
            guard let spec = plan.exactInstallSpec else { throw BridgeError.managerFailure(code: "npm-install-target-unavailable", detail: nil) }
            return [NodeAction.installPackage.rawValue, spec]
        }
        if plan.request.action == .updatePackage {
            guard let spec = plan.exactUpdateSpec else { throw BridgeError.managerFailure(code: "npm-update-not-behind", detail: nil) }
            // Frozen update-latest resolves latest again; pinned install enforces and verifies the confirmed version.
            return [NodeAction.installPackage.rawValue, spec]
        }
        var arguments = [plan.request.action.rawValue]
        if !plan.request.subject.isEmpty || plan.request.value != nil || plan.payload.planToken != nil {
            arguments.append(plan.request.subject)
        }
        switch plan.request.action {
        case .cleanup:
            if plan.request.subject == "logs", let keepCount = plan.request.value {
                arguments.append(keepCount)
            } else if let planToken = plan.payload.planToken {
                arguments.append(planToken)
            }
        default:
            if let value = plan.request.value {
                arguments.append(value)
            }
        }
        return arguments
    }
}

private func captureNodeRequest<Value: Sendable>(
    _ operation: @Sendable () async throws -> Value
) async -> Result<Value, Error> {
    do {
        return .success(try await operation())
    } catch {
        return .failure(error)
    }
}

private extension Result {
    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
