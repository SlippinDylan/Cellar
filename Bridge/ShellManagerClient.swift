import Foundation

actor ShellManagerClient {
    private let runner: ProcessRunner
    private let environmentResolver: ShellEnvironmentResolver
    private let validateTidySyntax: @Sendable (URL, URL) async throws -> Int32
    private var consumedConfigurations = Set<UUID>()
    private var tidyConfirmations: [UUID: (candidates: [String], file: ShellConfigurationFile)] = [:]

    init(
        runner: ProcessRunner,
        environmentResolver: ShellEnvironmentResolver = ShellEnvironmentResolver(),
        validateTidySyntax: (@Sendable (URL, URL) async throws -> Int32)? = nil
    ) {
        self.runner = runner
        self.environmentResolver = environmentResolver
        self.validateTidySyntax = validateTidySyntax ?? { configuration, directory in
            try Task.checkCancellation()
            return try await runner.run(ProcessRequest(executableURL: URL(filePath: "/bin/zsh"), arguments: ["-n", configuration.path],
                                                       environment: environmentResolver.environment(), currentDirectoryURL: directory, timeout: .seconds(30))).terminationStatus
        }
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
            defaultPluginNames: try builtInPlugins(at: URL(filePath: payload.ohMyZshPath), installed: payload.ohMyZshInstalled),
            runtimeDirectory: payload.runtimeDirectory,
            managerAvailable: managerAvailable
        )
    }

    func plan(_ request: ShellActionRequest, managerDirectory: URL) async throws -> ShellActionPlan {
        if request.action == .installPlugin {
            guard let url = TerminalPluginSource.repository(request.subject), url.absoluteString == request.subject else {
                throw BridgeError.managerFailure(code: "invalid-plugin-url", detail: nil)
            }
        }
        let payload: ShellActionPlanPayload = try await self.request(
            "plan",
            arguments: [request.action.rawValue, request.subject],
            managerDirectory: managerDirectory,
            environment: environmentResolver.environment()
        )
        guard payload.action == request.action.rawValue else {
            throw BridgeError.invalidOutput("Shell Manager 返回了不匹配的操作计划")
        }
        var plan = ShellActionPlan(id: UUID(), request: request, payload: payload, generatedAt: Date())
        if request.action == .tidy {
            plan.candidates = try tidyCandidates()
            tidyConfirmations[plan.id] = (plan.candidates, try ShellConfigurationFile.read(at: zshrcURL))
        }
        return plan
    }

    private func tidyCandidates() throws -> [String] {
        let home = zshrcURL.deletingLastPathComponent()
        let destination = home.appending(path: ".zsh")
        for directory in [destination, destination.appending(path: "backups")] {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw BridgeError.managerFailure(code: "tidy-unsafe-destination", detail: nil) }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile { /* The adapter creates these directories after confirmation. */ }
        }
        return try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
            .filter { file in
                let name = file.lastPathComponent
                guard name.hasPrefix(".zcompdump") || name.hasPrefix(".zshrc.backup-") || name.hasPrefix(".zshrc.backup.") || name.hasPrefix(".zshrc.bak.") || name == ".zprofile.bak" else { return false }
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else { throw BridgeError.managerFailure(code: "tidy-nonregular-candidate", detail: nil) }
                let target = (name.hasPrefix(".zcompdump") ? destination : destination.appending(path: "backups")).appending(path: name)
                do {
                    _ = try FileManager.default.attributesOfItem(atPath: target.path)
                    throw BridgeError.managerFailure(code: "tidy-destination-occupied", detail: nil)
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile { /* Never overwrite an existing completion file or backup. */ }
                return true
            }.map(\.path).sorted()
    }

    private func builtInPlugins(at root: URL, installed: Bool) throws -> [String] {
        guard installed else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root.appending(path: "plugins"), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
            .map(\.lastPathComponent).sorted()
    }

    func planConfiguration(plugins: [String], theme: String, managerDirectory: URL) async throws -> ShellConfigurationPlan {
        let snapshot = try await loadSnapshot(managerDirectory: managerDirectory, managerAvailable: true)
        let available = Set(snapshot.defaultPluginNames + snapshot.installedCustomPlugins)
        let selected = Set(plugins).union(["git"])
        guard selected.isSubset(of: available), snapshot.availableThemes.contains(theme) else {
            throw BridgeError.managerFailure(code: "terminal-selection-unavailable", detail: nil)
        }
        let original = try regularZshrcContents()
        var plans: [ShellActionPlan] = []
        if Set(snapshot.activePlugins) != selected {
            plans.append(try await plan(.init(action: .setPlugins, subject: selected.sorted().joined(separator: ",")), managerDirectory: managerDirectory))
        }
        if snapshot.currentTheme != theme {
            plans.append(try await plan(.init(action: .switchTheme, subject: theme), managerDirectory: managerDirectory))
        }
        guard original == (try regularZshrcContents()) else { throw BridgeError.managerFailure(code: "plan-stale", detail: nil) }
        var contents = original
        let expected = try plans.map { plan in
            contents = try Self.expectedConfiguration(contents, request: plan.request)
            return contents
        }
        return ShellConfigurationPlan(id: UUID(), plans: plans, originalContents: original, expectedContents: expected)
    }

    func executeConfiguration(_ configuration: ShellConfigurationPlan, managerDirectory: URL) async -> ShellConfigurationResult {
        var operations: [ShellOperationResult] = []
        var outcomes = configuration.plans.map { ShellStepOutcome(step: .init(action: $0.request.action), status: .unknown) }
        var activeStep: Int?
        do {
            guard configuration.canExecute, consumedConfigurations.insert(configuration.id).inserted,
                  configuration.originalContents == (try regularZshrcContents()) else { throw BridgeError.managerFailure(code: "plan-stale", detail: nil) }
            for (index, plan) in configuration.plans.enumerated() {
                activeStep = index
                let current = try await self.plan(plan.request, managerDirectory: managerDirectory)
                guard current.canExecute, current.payload.planToken == plan.payload.planToken else { throw BridgeError.managerFailure(code: "plan-stale", detail: nil) }
            }
            activeStep = nil
            for (index, originalPlan) in configuration.plans.enumerated() {
                activeStep = index
                try Task.checkCancellation()
                let expectedBefore = index == 0 ? configuration.originalContents : configuration.expectedContents[index - 1]
                guard expectedBefore == (try regularZshrcContents()), Date().timeIntervalSince(originalPlan.generatedAt) <= 300 else {
                    throw BridgeError.managerFailure(code: "plan-stale", detail: nil)
                }
                let currentPlan = index == 0 ? originalPlan : try await self.plan(originalPlan.request, managerDirectory: managerDirectory)
                guard expectedBefore == (try regularZshrcContents()) else { throw BridgeError.managerFailure(code: "plan-stale", detail: nil) }
                operations.append(try await execute(currentPlan, managerDirectory: managerDirectory))
                outcomes[index] = .init(step: outcomes[index].step, status: operations[index].status == "ok" ? .succeeded : .partiallySucceeded)
                guard configuration.expectedContents[index] == (try regularZshrcContents()) else { throw BridgeError.managerFailure(code: "terminal-state-changed", detail: nil) }
                activeStep = nil
            }
            return .init(operations: operations, failure: nil, stepOutcomes: outcomes)
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            if let index = activeStep {
                outcomes[index] = .init(step: outcomes[index].step, status: outcomes[index].status == .succeeded ? .partiallySucceeded : cancelled ? .cancelled : .failed)
            }
            if cancelled { outcomes = outcomes.map { $0.status == .unknown ? .init(step: $0.step, status: .cancelled) : $0 } }
            return .init(operations: operations, failure: error.localizedDescription, wasCancelled: cancelled, stepOutcomes: outcomes, failureReason: .init(error: error))
        }
    }

    private func regularZshrcContents() throws -> Data {
        try ShellConfigurationFile.read(at: zshrcURL).contents
    }

    private var zshrcURL: URL {
        guard let home = environmentResolver.environment()["HOME"] else { preconditionFailure("Shell environment requires HOME") }
        return URL(filePath: home).appending(path: ".zshrc")
    }

    // Mirror the adapter's marker replacement for verification, never for writing.
    static func expectedConfiguration(_ contents: Data, request: ShellActionRequest) throws -> Data {
        guard let text = String(data: contents, encoding: .utf8) else { throw BridgeError.invalidOutput("Invalid UTF-8 shell configuration") }
        let kind: String
        let value: String
        switch request.action {
        case .setPlugins: kind = "plugins"; value = "plugins=(\(request.subject.replacingOccurrences(of: ",", with: " ")))"
        case .switchTheme: kind = "theme"; value = "ZSH_THEME=\"\(request.subject)\""
        case .tidy: kind = "compdump"; value = "export ZSH_COMPDUMP=\"$HOME/.zsh/zcompdump\""
        default: throw BridgeError.managerFailure(code: "unsupported-configuration", detail: nil)
        }
        let start = "# >>> omz-manager \(kind) >>>"
        let end = "# <<< omz-manager \(kind) <<<"
        var lines: [String] = []
        var inBlock = false
        for line in text.components(separatedBy: "\n").dropLast(text.hasSuffix("\n") ? 1 : 0) {
            if line == start {
                guard !inBlock else { throw BridgeError.managerFailure(code: "invalid-managed-block", detail: nil) }
                inBlock = true
            } else if line == end {
                guard inBlock else { throw BridgeError.managerFailure(code: "invalid-managed-block", detail: nil) }
                inBlock = false
            } else if !inBlock { lines.append(line) }
        }
        guard !inBlock else { throw BridgeError.managerFailure(code: "invalid-managed-block", detail: nil) }
        while lines.last == "" { lines.removeLast() }
        if !lines.isEmpty { lines.append("") }
        lines.append(contentsOf: [start, value, end, ""])
        return Data(lines.joined(separator: "\n").utf8)
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
        if plan.request.action == .tidy {
            guard let confirmation = tidyConfirmations.removeValue(forKey: plan.id), confirmation.candidates == (try tidyCandidates()),
                  confirmation.file.matches(try ShellConfigurationFile.read(at: zshrcURL)) else {
                throw BridgeError.managerFailure(code: "plan-stale", detail: nil)
            }
            return try await executeTidy(plan, original: confirmation.file, managerDirectory: managerDirectory)
        }
        var environment = environmentResolver.environment()
        environment["SHELL_MANAGER_ALLOW_JSON_EXECUTE"] = "1"
        var rollbackRequest = plan.request
        if plan.request.action == .installPlugin {
            guard let url = TerminalPluginSource.repository(plan.request.subject) else { throw BridgeError.managerFailure(code: "invalid-plugin-url", detail: nil) }
            let snapshot = try await loadSnapshot(managerDirectory: managerDirectory, managerAvailable: true)
            let installed = Set(snapshot.defaultPluginNames + snapshot.installedCustomPlugins)
            var plugins: [String] = []
            for name in snapshot.activePlugins where installed.contains(name) && !plugins.contains(name) { plugins.append(name) }
            if !plugins.contains("git") { plugins.append("git") }
            let name = url.lastPathComponent
            if !plugins.contains(name) { plugins.append(name) }
            rollbackRequest = .init(action: .setPlugins, subject: plugins.joined(separator: ","))
        }
        let original = [.setPlugins, .switchTheme, .installPlugin].contains(plan.request.action) ? try regularZshrcContents() : nil
        do {
            return try await request(
                "execute", arguments: [plan.request.action.rawValue, plan.request.subject, plan.payload.planToken],
                managerDirectory: managerDirectory, environment: environment, timeout: .seconds(1_800)
            )
        } catch {
            if let original,
               (try regularZshrcContents()) == (try Self.expectedConfiguration(original, request: rollbackRequest)) {
                let validation = Task {
                    try await self.runner.run(ProcessRequest(executableURL: URL(filePath: "/bin/zsh"), arguments: ["-n", self.zshrcURL.path],
                                                            environment: self.environmentResolver.environment(), currentDirectoryURL: managerDirectory))
                }
                if try await validation.value.terminationStatus != 0 {
                    // Restore only the exact adapter-produced file; never overwrite an intervening edit.
                    guard (try regularZshrcContents()) == (try Self.expectedConfiguration(original, request: rollbackRequest)) else { throw error }
                    try original.write(to: zshrcURL, options: .atomic)
                    throw BridgeError.managerFailure(code: "shell-syntax-restored", detail: String(localized: "Shell syntax validation failed. The previous configuration was restored."))
                }
            }
            throw error
        }
    }

    private func executeTidy(_ plan: ShellActionPlan, original: ShellConfigurationFile, managerDirectory: URL) async throws -> ShellOperationResult {
        let expected = try Self.expectedConfiguration(original.contents, request: plan.request)
        var environment = environmentResolver.environment()
        environment["SHELL_MANAGER_ALLOW_JSON_EXECUTE"] = "1"
        let operation: ShellOperationResult = try await request("execute", arguments: [plan.request.action.rawValue, plan.request.subject, plan.payload.planToken],
                                                               managerDirectory: managerDirectory, environment: environment, timeout: .seconds(1_800))
        do {
            let current = try ShellConfigurationFile.read(at: zshrcURL)
            guard current.contents == expected else { throw BridgeError.managerFailure(code: "shell-restore-state-changed", detail: nil) }
            let validationFailed: Bool
            do { validationFailed = try await validateTidySyntax(zshrcURL, managerDirectory) != 0 }
            catch { validationFailed = true }
            if validationFailed {
                try original.restore(at: zshrcURL, replacing: expected)
                return .init(operationId: operation.operationId, action: operation.action, subject: operation.subject, status: "partial", exitCode: operation.exitCode,
                             logFile: operation.logFile, backupPath: operation.backupPath,
                             detail: String(localized: "Zsh files were moved, but syntax validation failed. The previous shell configuration and attributes were restored."))
            }
            return operation
        } catch {
            return .init(operationId: operation.operationId, action: operation.action, subject: operation.subject, status: "partial", exitCode: operation.exitCode,
                         logFile: operation.logFile, backupPath: operation.backupPath,
                         detail: String(localized: "Zsh files may have moved, but the shell configuration changed unexpectedly. It was not overwritten. Review diagnostics before trying again."))
        }
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
