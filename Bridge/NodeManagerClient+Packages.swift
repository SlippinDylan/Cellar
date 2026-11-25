import Foundation

extension NodeManagerClient {
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

    func packageDestination(_ summary: NodeSummary) throws -> NodePackageDestination {
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

    func scopeRegistryLayers(_ scope: String, summary: NodeSummary, managerDirectory: URL) async throws -> NPMRegistryLayers {
        guard SourceConfiguration.validScope(scope) else { throw CatalogSourceError.invalidURL }
        let exact = try await validatedDetectedEnvironment(summary, managerDirectory: managerDirectory)
        let fingerprint = try await registryFingerprint(environment: exact, managerDirectory: managerDirectory, summary: summary)
        let payload: NodeActionPlanPayload = try await request("plan", arguments: [NodeAction.deleteScopeRegistry.rawValue, scope],
                                                             managerDirectory: managerDirectory, environment: exact)
        guard let effective = payload.effectiveRegistry, let user = payload.userRegistry,
              let project = payload.projectRegistry, let global = payload.globalRegistry,
              [effective, user, project, global].allSatisfy({ $0 != "<unavailable>" })
        else { throw BridgeError.managerFailure(code: "registry-state-unavailable", detail: nil) }
        async let currentFingerprint = registryFingerprint(environment: exact, managerDirectory: managerDirectory, summary: summary)
        async let validated = validatedDetectedEnvironment(summary, managerDirectory: managerDirectory)
        _ = try await validated
        guard fingerprint == (try await currentFingerprint)
        else { throw BridgeError.managerFailure(code: "registry-state-changed", detail: nil) }
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
        guard let registryURL = SourceConfiguration.registryURL(value) else { throw CatalogSourceError.invalidURL }
        return registryURL
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
        try validatePackageEntries(summary, installation: installation)
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

    private func validatePackageEntries(_ summary: NodeSummary, installation: NodeInstallation) throws {
        guard NodeEnvironmentResolver.packageInstallation(summary: summary, installations: [installation]) != nil
        else { throw BridgeError.managerFailure(code: "node-environment-changed", detail: nil) }
    }


    func validateCleanupEvidence(_ operation: NodeOperationResult, plan: NodeActionPlan, failed: Bool) throws {
        guard operation.action == NodeAction.cleanup.rawValue, operation.subject == plan.request.subject,
              !operation.operationId.isEmpty, operation.exitCode >= 0,
              let items = operation.cleanupItems, items.count <= 1000, items.allSatisfy(\.hasValidEvidence),
              Set(items.map(\.path)).count == items.count,
              items.map(\.path) == plan.payload.paths,
              failed ? operation.exitCode != 0 && !items.isEmpty && items.contains(where: { $0.status != .removed })
                     : operation.exitCode == 0 && operation.status == "ok" && items.allSatisfy({ $0.status == .removed })
        else { throw BridgeError.invalidOutput("Cleanup result does not match the confirmed operation") }
        var stopped = false
        for item in items {
            guard stopped ? item.status == .notAttempted : item.status != .notAttempted else {
                throw BridgeError.invalidOutput("Cleanup result has inconsistent attempt order")
            }
            if item.status != .removed { stopped = true }
        }
        let expected: String
        if !failed { expected = "ok" }
        else if items.contains(where: { $0.status == .removed || $0.status == .partial }) { expected = "partial" }
        else if items.contains(where: { $0.status == .unknown }) { expected = "unknown" }
        else { expected = "failed" }
        guard operation.status == expected else { throw BridgeError.invalidOutput("Cleanup result has inconsistent completion evidence") }
    }

    func planArguments(for request: NodeActionRequest) -> [String] {
        var arguments = [request.action.rawValue]
        if !request.subject.isEmpty || request.value != nil {
            arguments.append(request.subject)
        }
        if let value = request.value {
            arguments.append(value)
        }
        return arguments
    }

    func executeArguments(for plan: NodeActionPlan) throws -> [String] {
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
