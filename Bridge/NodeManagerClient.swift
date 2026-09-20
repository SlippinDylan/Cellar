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
        preferredNodeVersion: String? = nil
    ) async throws -> NodeSnapshot {
        let environment = environmentResolver.environment(preferredNodeVersion: preferredNodeVersion)
        let summaryValue: NodeSummary = try await request(
            "summary", managerDirectory: managerDirectory, environment: environment
        )
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
        do {
            let outdated: [String: OutdatedPackage] = try await request(
                "outdated", managerDirectory: managerDirectory, environment: environment
            )
            outdatedResult = .success(outdated)
        } catch {
            outdatedResult = .failure(error)
        }
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
            summary: summaryValue,
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

    func plan(
        _ request: NodeActionRequest,
        managerDirectory: URL,
        preferredNodeVersion: String? = nil
    ) async throws -> NodeActionPlan {
        let environment = environmentResolver.environment(preferredNodeVersion: preferredNodeVersion)
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
        guard plan.canExecute else {
            throw BridgeError.managerFailure(
                code: plan.payload.blockedReason ?? "plan-not-executable",
                detail: "Node 操作计划当前不可执行"
            )
        }
        guard Date().timeIntervalSince(plan.generatedAt) <= 300 else {
            throw BridgeError.managerFailure(code: "plan-expired", detail: "Node 操作计划已过期，请重新生成")
        }

        var environment = environmentResolver.environment(preferredNodeVersion: preferredNodeVersion)
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
