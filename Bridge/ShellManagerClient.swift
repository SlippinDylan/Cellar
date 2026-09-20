import Foundation

actor ShellManagerClient {
    private let runner: ProcessRunner
    private let environmentResolver: ShellEnvironmentResolver

    init(
        runner: ProcessRunner,
        environmentResolver: ShellEnvironmentResolver = ShellEnvironmentResolver()
    ) {
        self.runner = runner
        self.environmentResolver = environmentResolver
    }

    func loadSnapshot(managerDirectory: URL, managerAvailable: Bool) async throws -> ShellStatus {
        let payload: ShellSnapshotPayload = try await request(
            "snapshot",
            managerDirectory: managerDirectory,
            environment: environmentResolver.environment()
        )
        return ShellStatus(
            zshVersion: payload.zshVersion,
            ohMyZshPath: payload.ohMyZshPath,
            ohMyZshInstalled: payload.ohMyZshInstalled,
            zshrcPath: payload.zshrcPath,
            zshrcExists: payload.zshrcExists,
            currentTheme: payload.currentTheme,
            activePlugins: payload.activePlugins,
            installedCustomPlugins: payload.installedCustomPlugins,
            availableThemes: payload.availableThemes,
            defaultPluginNames: payload.defaultPluginNames,
            runtimeDirectory: payload.runtimeDirectory,
            managerAvailable: managerAvailable
        )
    }

    func plan(_ request: ShellActionRequest, managerDirectory: URL) async throws -> ShellActionPlan {
        let payload: ShellActionPlanPayload = try await self.request(
            "plan",
            arguments: [request.action.rawValue, request.subject],
            managerDirectory: managerDirectory,
            environment: environmentResolver.environment()
        )
        guard payload.action == request.action.rawValue else {
            throw BridgeError.invalidOutput("Shell Manager 返回了不匹配的操作计划")
        }
        return ShellActionPlan(id: UUID(), request: request, payload: payload, generatedAt: Date())
    }

    func execute(_ plan: ShellActionPlan, managerDirectory: URL) async throws -> ShellOperationResult {
        guard plan.canExecute else {
            throw BridgeError.managerFailure(
                code: plan.payload.blockedReason.isEmpty ? "plan-not-executable" : plan.payload.blockedReason,
                detail: "Shell 操作计划当前不可执行"
            )
        }
        guard Date().timeIntervalSince(plan.generatedAt) <= 300 else {
            throw BridgeError.managerFailure(code: "plan-expired", detail: "Shell 操作计划已过期，请重新生成")
        }
        var environment = environmentResolver.environment()
        environment["SHELL_MANAGER_ALLOW_JSON_EXECUTE"] = "1"
        return try await request(
            "execute",
            arguments: [plan.request.action.rawValue, plan.request.subject, plan.payload.planToken],
            managerDirectory: managerDirectory,
            environment: environment,
            timeout: .seconds(1_800)
        )
    }

    private func request<Payload: Decodable & Sendable>(
        _ command: String,
        arguments: [String] = [],
        managerDirectory: URL,
        environment: [String: String],
        timeout: Duration? = .seconds(300)
    ) async throws -> Payload {
        let adapter = managerDirectory.appending(path: "app-json.sh")
        guard FileManager.default.isExecutableFile(atPath: adapter.path) else {
            throw BridgeError.executableNotFound(adapter.path)
        }
        let result = try await runner.run(ProcessRequest(
            executableURL: URL(filePath: "/bin/bash"),
            arguments: [adapter.path, "--json", command] + arguments,
            environment: environment,
            currentDirectoryURL: managerDirectory,
            timeout: timeout
        ))
        let envelope: ManagerEnvelope<Payload>
        do {
            envelope = try JSONDecoder().decode(ManagerEnvelope<Payload>.self, from: result.standardOutput)
        } catch {
            let output = result.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
            let diagnostic = result.errorText.nilIfBlank
                ?? (output.isEmpty ? nil : String(output.prefix(500)))
                ?? error.localizedDescription
            throw BridgeError.invalidOutput(diagnostic)
        }
        guard envelope.schemaVersion == 1 else {
            throw BridgeError.unsupportedSchema(envelope.schemaVersion)
        }
        guard result.terminationStatus == 0, envelope.ok, let payload = envelope.data else {
            throw BridgeError.managerFailure(
                code: envelope.error?.code ?? "exit-\(result.terminationStatus)",
                detail: envelope.error?.message ?? envelope.error?.stderr ?? result.errorText.nilIfBlank
            )
        }
        return payload
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
