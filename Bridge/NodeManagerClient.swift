import CryptoKit
import Foundation

actor NodeManagerClient {
    private static let confirmationLifetime: Duration = .seconds(300)

    let runner: ProcessRunner
    let environmentResolver: NodeEnvironmentResolver
    private var registryConfirmations: [UUID: (environment: [String: String], fingerprint: String, summary: NodeSummary, recordedAt: ContinuousClock.Instant)] = [:]
    private var environmentConfirmations: [UUID: (environment: [String: String], summary: NodeSummary, fingerprint: String, recordedAt: ContinuousClock.Instant)] = [:]
    private var packageConfirmations: [UUID: (context: NodeEnvironmentContext, recordedAt: ContinuousClock.Instant)] = [:]
    private var configurationConfirmations: [UUID: (environment: [String: String], fingerprint: String, recordedAt: ContinuousClock.Instant)] = [:]
    private var logConfirmations: [UUID: (state: NodeLogMaintenanceState, recordedAt: ContinuousClock.Instant)] = [:]

    private func pruneExpiredConfirmations(now: ContinuousClock.Instant = .now) {
        registryConfirmations = registryConfirmations.filter { $0.value.recordedAt.duration(to: now) <= Self.confirmationLifetime }
        environmentConfirmations = environmentConfirmations.filter { $0.value.recordedAt.duration(to: now) <= Self.confirmationLifetime }
        packageConfirmations = packageConfirmations.filter { $0.value.recordedAt.duration(to: now) <= Self.confirmationLifetime }
        configurationConfirmations = configurationConfirmations.filter { $0.value.recordedAt.duration(to: now) <= Self.confirmationLifetime }
        logConfirmations = logConfirmations.filter { $0.value.recordedAt.duration(to: now) <= Self.confirmationLifetime }
    }

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

    func loadSnapshot(
        managerDirectory: URL,
        preferredNodeVersion: String?,
        environment: [String: String],
        summary: NodeSummary,
        includingOutdated: Bool = true
    ) async throws -> NodeSnapshot {
        async let inventoryTask: NodePackageInventory = request(
            "packages", managerDirectory: managerDirectory, environment: environment
        )
        async let configurationTask: NodeConfiguration = request(
            "config", managerDirectory: managerDirectory, environment: environment
        )
        async let statusTask: Result<NodeManagerStatus, Error> = captureNodeRequest {
            try await self.request("status", managerDirectory: managerDirectory, environment: environment)
        }
        async let logsTask: Result<[String], Error> = captureNodeRequest {
            try await self.request(
                "logs", arguments: ["20"], managerDirectory: managerDirectory, environment: environment
            )
        }
        async let outdatedTask: Result<[String: OutdatedPackage], Error> = includingOutdated
            ? captureNodeRequest {
                try await self.request("outdated", managerDirectory: managerDirectory, environment: environment)
            }
            : .success([:])

        let inventoryValue = try await inventoryTask
        let configurationValue = try await configurationTask
        let statusResult = await statusTask
        let logsResult = await logsTask
        let outdatedResult = await outdatedTask

        if let error = statusResult.failure, error is CancellationError { throw error }
        if let error = logsResult.failure, error is CancellationError { throw error }
        if let error = outdatedResult.failure, error is CancellationError { throw error }
        let outdatedValue = (try? outdatedResult.get()) ?? [:]
        let packages: [NodePackageRow] = (inventoryValue.dependencies ?? [:]).map { name, package in
            let available = outdatedValue[name]
            return NodePackageRow(
                name: name,
                installedVersion: package.version ?? String(localized: "Unknown"),
                wantedVersion: available?.wanted,
                latestVersion: available?.latest
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        try Task.checkCancellation()
        let outdatedError = outdatedResult.failure?.localizedDescription
        let installations = environmentResolver.installations(preferredNodeVersion: preferredNodeVersion)
        let packageEnvironment = NodeEnvironmentResolver.packageInstallation(
            summary: summary,
            installations: installations,
            approvedSystemPrefixes: environmentResolver.approvedSystemPrefixes
        ).map { _ in LibraryCatalog.context(summary) }
        return NodeSnapshot(
            summary: summary,
            configuration: configurationValue,
            packages: packages,
            installations: installations,
            managerStatus: try? statusResult.get(),
            logs: (try? logsResult.get()) ?? [],
            outdatedError: outdatedError,
            maintenanceError: [statusResult.failure, logsResult.failure]
                .compactMap { $0?.localizedDescription }
                .joined(separator: "; ")
                .nilIfBlank,
            packageEnvironment: packageEnvironment
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
        preferredNodeVersion: String? = nil,
        detectedSummary: NodeSummary? = nil
    ) async throws -> NodeActionPlan {
        var environment = environmentResolver.environment(preferredNodeVersion: preferredNodeVersion)
        let request = try normalizedRegistryRequest(request)
        if [.installPackage, .updatePackage, .uninstallPackage].contains(request.action) {
            let summary: NodeSummary
            if let detectedSummary { summary = detectedSummary }
            else { summary = try await self.request("summary", managerDirectory: managerDirectory, environment: environment) }
            let context = LibraryCatalog.context(summary)
            let plan = try await planPackage(.init(name: request.subject, environment: context), action: request.action, managerDirectory: managerDirectory)
            pruneExpiredConfirmations()
            packageConfirmations[plan.id] = (context, .now)
            return plan
        }
        if request.action.isRegistryConfiguration || requiresDetectedNPM(request) {
            _ = try registryFileFingerprint(environment: environment, managerDirectory: managerDirectory)
            let summary: NodeSummary
            if let detectedSummary { summary = detectedSummary }
            else { summary = try await self.request("summary", managerDirectory: managerDirectory, environment: environment) }
            environment = try await validatedDetectedEnvironment(summary, managerDirectory: managerDirectory)
            let fingerprint = try await registryFingerprint(environment: environment, managerDirectory: managerDirectory, summary: summary)
            let plan = try await self.plan(request, managerDirectory: managerDirectory, environment: environment)
            guard fingerprint == (try await registryFingerprint(environment: environment, managerDirectory: managerDirectory, summary: summary)) else { throw BridgeError.managerFailure(code: "plan-stale", detail: nil) }
            pruneExpiredConfirmations()
            if request.action.isRegistryConfiguration {
                guard plan.payload.effectiveRegistry != nil else { throw BridgeError.managerFailure(code: "registry-state-unavailable", detail: nil) }
                registryConfirmations[plan.id] = (environment, fingerprint, summary, .now)
            } else {
                environmentConfirmations[plan.id] = (environment, summary, fingerprint, .now)
            }
            return plan
        }
        if request.action == .cleanup, request.subject == NodeMaintenanceAction.logs.rawValue {
            guard request.value == "100" else { throw BridgeError.managerFailure(code: "invalid-log-retention", detail: nil) }
            let state = try NodeLogMaintenanceState.read(managerDirectory: managerDirectory)
            let plan = try await self.plan(request, managerDirectory: managerDirectory, environment: environment)
            guard state == (try NodeLogMaintenanceState.read(managerDirectory: managerDirectory)) else { throw BridgeError.managerFailure(code: "plan-stale", detail: nil) }
            pruneExpiredConfirmations()
            logConfirmations[plan.id] = (state, .now)
            return NodeActionPlan(id: plan.id, request: request, payload: plan.payload, generatedAt: plan.generatedAt, maintenanceCandidates: state.candidates)
        }
        if [.setDefaultNode, .uninstallNode].contains(request.action) {
            let fingerprint = try configurationFingerprint(request, environment: environment)
            let plan = try await self.plan(request, managerDirectory: managerDirectory, environment: environment)
            guard fingerprint == (try configurationFingerprint(request, environment: environment)) else { throw BridgeError.managerFailure(code: "plan-stale", detail: nil) }
            pruneExpiredConfirmations()
            configurationConfirmations[plan.id] = (environment, fingerprint, .now)
            return plan
        }
        return try await plan(request, managerDirectory: managerDirectory, environment: environment)
    }

    func plan(
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
            throw BridgeError.invalidOutput("Node Manager returned a mismatched action plan")
        }
        return NodeActionPlan(id: UUID(), request: request, payload: payload, generatedAt: Date())
    }

    func execute(
        _ plan: NodeActionPlan,
        managerDirectory: URL,
        preferredNodeVersion: String? = nil
    ) async throws -> NodeOperationResult {
        pruneExpiredConfirmations()
        var environment = environmentResolver.environment(preferredNodeVersion: preferredNodeVersion)
        if [.installPackage, .updatePackage, .uninstallPackage].contains(plan.request.action) {
            guard let entry = packageConfirmations.removeValue(forKey: plan.id) else { throw BridgeError.managerFailure(code: "node-environment-changed", detail: nil) }
            return try await executePackage(plan, environment: entry.context, managerDirectory: managerDirectory)
        }
        if requiresDetectedNPM(plan.request) {
            guard let baseline = environmentConfirmations.removeValue(forKey: plan.id) else { throw BridgeError.managerFailure(code: "node-environment-changed", detail: nil) }
            environment = try await validatedDetectedEnvironment(baseline.summary, managerDirectory: managerDirectory)
            guard environment == baseline.environment,
                  baseline.fingerprint == (try await registryFingerprint(environment: environment, managerDirectory: managerDirectory, summary: baseline.summary))
            else { throw BridgeError.managerFailure(code: "plan-stale", detail: nil) }
        }
        if plan.request.action == .cleanup, plan.request.subject == NodeMaintenanceAction.logs.rawValue {
            guard let entry = logConfirmations.removeValue(forKey: plan.id), entry.state == (try NodeLogMaintenanceState.read(managerDirectory: managerDirectory)) else { throw BridgeError.managerFailure(code: "plan-stale", detail: nil) }
            let state = entry.state
            let result = try await execute(plan, managerDirectory: managerDirectory, environment: environment)
            guard result.action == NodeAction.cleanup.rawValue, result.subject == plan.request.subject, !result.operationId.isEmpty else {
                throw BridgeError.invalidOutput("Log cleanup result does not match the confirmed operation")
            }
            let detail: String?
            let items: [NodeCleanupItem]
            do {
                _ = try NodeLogMaintenanceState.read(managerDirectory: managerDirectory)
                // Include replaced files and symlinks, not only regular log entries.
                let remaining = try FileManager.default.contentsOfDirectory(at: managerDirectory.appending(path: ".runtime/logs"), includingPropertiesForKeys: nil)
                let paths = Set(remaining.map(\.path))
                items = state.candidates.map { path in
                    paths.contains(path) ? .init(path: path, status: .unknown, reason: .cleanupFailed)
                        : .init(path: path, status: .removed, reason: .removed)
                }
                detail = items.contains { $0.status == .unknown } ? "log-candidates-remain" : nil
            } catch {
                items = state.candidates.map { .init(path: $0, status: .unknown, reason: .cleanupFailed) }
                detail = "log-verification-unavailable"
            }
            return NodeOperationResult(operationId: result.operationId, action: result.action, subject: result.subject,
                                       exitCode: result.exitCode, status: detail == nil ? result.status : "unknown",
                                       logFile: result.logFile, detail: detail ?? result.detail, residues: result.residues, cleanupItems: items.isEmpty ? nil : items)
        }
        if [.setDefaultNode, .uninstallNode].contains(plan.request.action) {
            guard let baseline = configurationConfirmations.removeValue(forKey: plan.id), baseline.environment == environment,
                  baseline.fingerprint == (try configurationFingerprint(plan.request, environment: environment)) else { throw BridgeError.managerFailure(code: "plan-stale", detail: nil) }
            let current = try await self.plan(plan.request, managerDirectory: managerDirectory, environment: environment)
            guard current.canExecute, current.payload.normalizedVersion == plan.payload.normalizedVersion,
                  current.payload.currentVersion == plan.payload.currentVersion, current.payload.defaultVersion == plan.payload.defaultVersion,
                  current.payload.versionDir == plan.payload.versionDir, current.payload.globalPackageSummary == plan.payload.globalPackageSummary,
                  baseline.fingerprint == (try configurationFingerprint(plan.request, environment: environment)) else { throw BridgeError.managerFailure(code: "plan-stale", detail: nil) }
        }
        if plan.request.action.isRegistryConfiguration {
            guard let baseline = registryConfirmations.removeValue(forKey: plan.id) else { throw BridgeError.managerFailure(code: "registry-state-changed", detail: nil) }
            environment = try await validatedDetectedEnvironment(baseline.summary, managerDirectory: managerDirectory)
            guard baseline.environment == environment,
                  baseline.fingerprint == (try await registryFingerprint(environment: environment, managerDirectory: managerDirectory, summary: baseline.summary))
            else { throw BridgeError.managerFailure(code: "registry-state-changed", detail: nil) }
            let current = try await self.plan(plan.request, managerDirectory: managerDirectory, environment: environment)
            guard current.payload.effectiveRegistry == plan.payload.effectiveRegistry,
                  current.payload.userRegistry == plan.payload.userRegistry,
                  current.payload.projectRegistry == plan.payload.projectRegistry,
                  current.payload.globalRegistry == plan.payload.globalRegistry,
                  baseline.fingerprint == (try await registryFingerprint(environment: environment, managerDirectory: managerDirectory, summary: baseline.summary))
            else { throw BridgeError.managerFailure(code: "registry-state-changed", detail: nil) }
        }
        return try await execute(plan, managerDirectory: managerDirectory, environment: environment)
    }

    private func normalizedRegistryRequest(_ request: NodeActionRequest) throws -> NodeActionRequest {
        switch request.action {
        case .setRegistry:
            guard let url = SourceConfiguration.registryURL(request.subject) else { throw CatalogSourceError.invalidURL }
            return .init(action: request.action, subject: url.absoluteString)
        case .setScopeRegistry:
            guard SourceConfiguration.validScope(request.subject), let value = request.value,
                  let url = SourceConfiguration.registryURL(value) else { throw CatalogSourceError.invalidURL }
            return .init(action: request.action, subject: request.subject, value: url.absoluteString)
        case .deleteScopeRegistry:
            guard SourceConfiguration.validScope(request.subject) else { throw CatalogSourceError.invalidURL }
        default: break
        }
        return request
    }

    private func requiresDetectedNPM(_ request: NodeActionRequest) -> Bool {
        request.action == .cleanup && ["npm-cache-verify", "npm-cache-clean", "node-gyp-cache", "orphan-bins"].contains(request.subject)
    }

    func validatedDetectedEnvironment(_ summary: NodeSummary, managerDirectory: URL) async throws -> [String: String] {
        guard [summary.nodePath, summary.npmPath, summary.globalPrefix, summary.globalRoot].allSatisfy({ $0.hasPrefix("/") }),
              FileManager.default.isExecutableFile(atPath: summary.nodePath), FileManager.default.isExecutableFile(atPath: summary.npmPath)
        else { throw BridgeError.managerFailure(code: "node-environment-changed", detail: nil) }
        let environment = environmentResolver.environment(nodeExecutable: URL(filePath: summary.nodePath), npmExecutable: URL(filePath: summary.npmPath))
        let current: NodeSummary = try await request("summary", managerDirectory: managerDirectory, environment: environment)
        guard current.nodePath == summary.nodePath, current.npmPath == summary.npmPath,
              current.nodeVersion == summary.nodeVersion, current.npmVersion == summary.npmVersion,
              current.globalPrefix == summary.globalPrefix, current.globalRoot == summary.globalRoot
        else { throw BridgeError.managerFailure(code: "node-environment-changed", detail: nil) }
        return environment
    }

    func registryFingerprint(environment: [String: String], managerDirectory: URL, summary: NodeSummary) async throws -> String {
        _ = try registryFileFingerprint(environment: environment, managerDirectory: managerDirectory)
        let npmURL = URL(filePath: summary.npmPath)
        let runner = self.runner
        func queryPath(_ arguments: [String]) async throws -> String {
            let result = try await runner.run(ProcessRequest(executableURL: npmURL, arguments: arguments,
                                                             environment: environment, currentDirectoryURL: managerDirectory, timeout: .seconds(20)))
            let path = result.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.terminationStatus == 0, !result.standardOutputWasTruncated, !result.standardErrorWasTruncated,
                  path.hasPrefix("/"), !path.contains("\n") else { throw BridgeError.managerFailure(code: "registry-state-unavailable", detail: nil) }
            return path
        }
        async let globalConfigPath = queryPath(["config", "get", "globalconfig"])
        async let userConfigPath = queryPath(["config", "get", "userconfig"])
        async let prefixPath = queryPath(["prefix"])
        async let cachePath = queryPath(["config", "get", "cache"])
        let (globalConfig, userConfig, prefix, cache) = try await (globalConfigPath, userConfigPath, prefixPath, cachePath)
        let files = [
            URL(filePath: summary.globalPrefix).appending(path: "etc/npmrc"),
            URL(filePath: globalConfig),
            URL(filePath: userConfig),
            URL(filePath: prefix).appending(path: ".npmrc")
        ]
        let destination = try packageDestination(summary)
        let fingerprint = try registryFileFingerprint(environment: environment, managerDirectory: managerDirectory, additionalFiles: files)
        return SHA256.hash(data: Data([fingerprint, destination.nodeExecutable, destination.npmExecutable, destination.globalPrefix, destination.globalRoot, cache].joined(separator: "\0").utf8)).description
    }

    private func registryFileFingerprint(environment: [String: String], managerDirectory: URL, additionalFiles: [URL] = []) throws -> String {
        guard let home = environment["HOME"] else { throw BridgeError.managerFailure(code: "registry-home-unavailable", detail: nil) }
        var files = [URL(filePath: home).appending(path: ".npmrc"), managerDirectory.appending(path: ".npmrc")] + additionalFiles
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
        let files = [URL(filePath: home).appending(path: ".nvm/alias/default")]
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

    func execute(
        _ plan: NodeActionPlan,
        managerDirectory: URL,
        environment: [String: String]
    ) async throws -> NodeOperationResult {
        guard plan.canExecute else {
            throw BridgeError.managerFailure(
                code: plan.payload.blockedReason ?? "plan-not-executable",
                detail: "Node action plan is not executable"
            )
        }
        guard Date().timeIntervalSince(plan.generatedAt) <= 300 else {
            throw BridgeError.managerFailure(code: "plan-expired", detail: "Node action plan has expired")
        }

        var environment = environment
        environment["NODE_MANAGER_ALLOW_JSON_EXECUTE"] = "1"
        if plan.request.action == .cleanup, ["npm-cache-clean", "node-gyp-cache", "orphan-bins", "nvm-old-versions", "logs"].contains(plan.request.subject) {
            let result = try await runManager("execute", arguments: try executeArguments(for: plan),
                                              managerDirectory: managerDirectory, environment: environment, timeout: .seconds(1_800))
            let envelope: ManagerEnvelope<NodeOperationResult> = try decodeEnvelope(result)
            guard envelope.command == "execute", envelope.ok || envelope.data == nil else {
                throw BridgeError.invalidOutput("Cleanup response has an invalid envelope")
            }
            if plan.request.subject == "logs" {
                if !envelope.ok, let error = envelope.error, error.code == "logs-cleanup-failed", let operation = error.cleanupOperation {
                    let logDirectory = managerDirectory.appending(path: ".runtime/logs").resolvingSymlinksInPath().path
                    guard result.terminationStatus == operation.exitCode,
                          URL(filePath: operation.logFile).deletingLastPathComponent().resolvingSymlinksInPath().path == logDirectory else {
                        throw BridgeError.invalidOutput("Log cleanup failure does not match its process and log directory")
                    }
                    return operation
                }
                return try requireSuccess(envelope, result: result)
            }
            if !envelope.ok, result.terminationStatus != 0,
               let error = envelope.error, error.code == "cleanup-incomplete", let operation = error.cleanupOperation {
                try validateCleanupEvidence(operation, plan: plan, failed: true)
                return operation
            }
            let operation: NodeOperationResult = try requireSuccess(envelope, result: result)
            if operation.cleanupItems != nil { try validateCleanupEvidence(operation, plan: plan, failed: false) }
            return operation
        }
        return try await request(
            "execute",
            arguments: try executeArguments(for: plan),
            managerDirectory: managerDirectory,
            environment: environment,
            timeout: .seconds(1_800)
        )
    }

    func request<Payload: Decodable & Sendable>(
        _ command: String,
        arguments: [String] = [],
        managerDirectory: URL,
        environment: [String: String],
        timeout: Duration? = .seconds(300)
    ) async throws -> Payload {
        let result = try await runManager(command, arguments: arguments, managerDirectory: managerDirectory,
                                          environment: environment, timeout: timeout)
        return try requireSuccess(decodeEnvelope(result), result: result)
    }

    private func runManager(_ command: String, arguments: [String], managerDirectory: URL,
                            environment: [String: String], timeout: Duration?) async throws -> ProcessResult {
        let mainScript = managerDirectory.appending(path: "main.sh")
        guard FileManager.default.isReadableFile(atPath: mainScript.path) else {
            throw BridgeError.executableNotFound(mainScript.path)
        }

        return try await runner.run(ProcessRequest(
            executableURL: URL(filePath: "/bin/bash"),
            arguments: [mainScript.path, "--json", command] + arguments,
            environment: environment,
            currentDirectoryURL: managerDirectory,
            timeout: timeout
        ))
    }

    private func decodeEnvelope<Payload>(_ result: ProcessResult) throws -> ManagerEnvelope<Payload> {
        guard !result.standardOutputWasTruncated, !result.standardErrorWasTruncated else {
            throw BridgeError.invalidOutput("Node Manager output was truncated")
        }
        let envelope: ManagerEnvelope<Payload>
        do { envelope = try JSONDecoder().decode(ManagerEnvelope<Payload>.self, from: result.standardOutput) }
        catch {
            let diagnostic = result.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BridgeError.invalidOutput(diagnostic.isEmpty ? error.localizedDescription : diagnostic)
        }
        guard envelope.schemaVersion == 1 else { throw BridgeError.unsupportedSchema(envelope.schemaVersion) }
        return envelope
    }

    private func requireSuccess<Payload>(_ envelope: ManagerEnvelope<Payload>, result: ProcessResult) throws -> Payload {
        guard result.terminationStatus == 0, envelope.ok, let payload = envelope.data else {
            let managerError = envelope.error
            let detail = managerError?.message ?? managerError?.stderr ?? result.errorText.nilIfBlank
            throw BridgeError.managerFailure(code: managerError?.code ?? "exit-\(result.terminationStatus)", detail: detail)
        }
        return payload
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
