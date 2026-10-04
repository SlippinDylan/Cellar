import Foundation

actor NodeManagerClient {
    private let runner: ProcessRunner
    private let environmentResolver: NodeEnvironmentResolver

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
        return try await execute(plan, managerDirectory: managerDirectory, environment: environment)
    }

    private func execute(
        _ plan: NodeActionPlan,
        managerDirectory: URL,
        environment: [String: String]
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

        var environment = environment
        environment["NODE_MANAGER_ALLOW_JSON_EXECUTE"] = "1"
        if plan.request.action == .writeProjectNVMRC {
            environment["NODE_MANAGER_ALLOW_PROJECT_WRITE"] = "1"
        }
        return try await request(
            "execute",
            arguments: executeArguments(for: plan),
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
        return try await plan(.init(action: action, subject: identity.name), managerDirectory: managerDirectory,
                              environment: validated.environment)
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
        }
        return try await execute(plan, managerDirectory: managerDirectory, environment: validated.environment)
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

    private func executeArguments(for plan: NodeActionPlan) -> [String] {
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
