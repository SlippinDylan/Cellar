import Darwin
import Foundation

actor ShellManagerClient {
    static let compdumpComment = "# Zsh completion dump location"
    static let compdumpSetting = #"export ZSH_COMPDUMP="$HOME/.cache/zsh/.zcompdump-$HOST""#

    let runner: ProcessRunner
    let environmentResolver: ShellEnvironmentResolver
    private let executionTimeout: Duration
    private let beforePluginPublication: @Sendable () async -> Void
    let validateSyntax: @Sendable (URL, URL) async throws -> Int32
    private var consumedConfigurations = Set<UUID>()
    private var tidyConfirmations: [UUID: TidyConfirmation] = [:]

    init(
        runner: ProcessRunner,
        environmentResolver: ShellEnvironmentResolver = ShellEnvironmentResolver(),
        executionTimeout: Duration = .seconds(1_800),
        beforePluginPublication: @escaping @Sendable () async -> Void = {},
        validateSyntax: (@Sendable (URL, URL) async throws -> Int32)? = nil
    ) {
        self.runner = runner
        self.environmentResolver = environmentResolver
        self.executionTimeout = executionTimeout
        self.beforePluginPublication = beforePluginPublication
        self.validateSyntax = validateSyntax ?? { configuration, directory in
            try Task.checkCancellation()
            return try await runner.run(ProcessRequest(
                executableURL: URL(filePath: "/bin/zsh"),
                arguments: ["-n", configuration.path],
                environment: environmentResolver.environment(),
                currentDirectoryURL: directory,
                timeout: .seconds(30)
            )).terminationStatus
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
            throw BridgeError.invalidOutput("Shell Manager returned a mismatched action plan")
        }
        var plan = ShellActionPlan(id: UUID(), request: request, payload: payload, generatedAt: Date())
        if plan.canExecute, [.setPlugins, .switchTheme].contains(request.action) {
            let contents = try regularZshrcContents()
            _ = try Self.applyZshrcUpdate(contents, request: request)
        }
        if plan.canExecute, request.action == .tidy {
            let discovery = try discoverTidyCandidates()
            let zshenvFile = try readOptionalConfigurationFile(at: zshenvURL, symlinkCode: "zshenv-is-symlink")
            let zshrcFile = try readOptionalConfigurationFile(at: zshrcURL, symlinkCode: "zshrc-not-regular-file")
            if let zshenvFile { _ = try Self.updatedZshenvForTidy(zshenvFile.contents) }
            if let zshrcFile { _ = try Self.cleanedZshrcForTidy(zshrcFile.contents) }
            plan.candidates = discovery.allPaths
            tidyConfirmations[plan.id] = TidyConfirmation(
                staleCompdumps: discovery.staleCompdumps,
                backupFiles: discovery.backupFiles,
                zshenv: zshenvFile,
                zshrc: zshrcFile
            )
        }
        return plan
    }

    func planConfiguration(plugins: [String], theme: String, managerDirectory: URL) async throws -> ShellConfigurationPlan {
        let snapshot = try await loadSnapshot(managerDirectory: managerDirectory, managerAvailable: true)
        let available = Set(snapshot.defaultPluginNames + snapshot.installedCustomPlugins)
        let selected = Set(plugins).union(["git"])
        guard selected.isSubset(of: available),
              snapshot.availableThemes.contains(theme) || theme == snapshot.currentTheme else {
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
            contents = try Self.applyZshrcUpdate(contents, request: plan.request)
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
                  configuration.originalContents == (try regularZshrcContents()) else {
                throw BridgeError.managerFailure(code: "plan-stale", detail: nil)
            }
            for (index, originalPlan) in configuration.plans.enumerated() {
                activeStep = index
                try Task.checkCancellation()
                let expectedBefore = index == 0 ? configuration.originalContents : configuration.expectedContents[index - 1]
                guard expectedBefore == (try regularZshrcContents()), Date().timeIntervalSince(originalPlan.generatedAt) <= 300 else {
                    throw BridgeError.managerFailure(code: "plan-stale", detail: nil)
                }
                let currentPlan = index == 0 ? originalPlan : try await self.plan(originalPlan.request, managerDirectory: managerDirectory)
                let operation = try await execute(currentPlan, managerDirectory: managerDirectory)
                operations.append(operation)
                outcomes[index] = .init(step: outcomes[index].step, status: operation.status == "ok" ? .succeeded : .partiallySucceeded)
                guard configuration.expectedContents[index] == (try regularZshrcContents()) else {
                    throw BridgeError.managerFailure(code: "terminal-state-changed", detail: nil)
                }
                activeStep = nil
            }
            return .init(operations: operations, failure: nil, stepOutcomes: outcomes)
        } catch {
            let evidence = error as? ShellExecutionFailure
            if let operation = evidence?.operation { operations.append(operation) }
            let cancelled = error is CancellationError || Task.isCancelled
            if let index = activeStep {
                outcomes[index] = .init(
                    step: outcomes[index].step,
                    status: evidence?.outcome.itemStatus ?? (outcomes[index].status == .succeeded ? .partiallySucceeded : cancelled ? .cancelled : .failed)
                )
            }
            if cancelled {
                outcomes = outcomes.enumerated().map { index, outcome in
                    outcome.status == .unknown && index != activeStep ? .init(step: outcome.step, status: .cancelled) : outcome
                }
            }
            return .init(
                operations: operations,
                failure: evidence?.diagnosticDetail ?? error.localizedDescription,
                wasCancelled: cancelled,
                stepOutcomes: outcomes,
                failureReason: evidence?.reason ?? .init(error: error)
            )
        }
    }

    func execute(_ plan: ShellActionPlan, managerDirectory: URL) async throws -> ShellOperationResult {
        guard plan.canExecute else {
            throw BridgeError.managerFailure(
                code: plan.payload.blockedReason.isEmpty ? "plan-not-executable" : plan.payload.blockedReason,
                detail: "Shell action plan is not executable"
            )
        }
        guard Date().timeIntervalSince(plan.generatedAt) <= 300 else {
            throw BridgeError.managerFailure(code: "plan-expired", detail: "Shell action plan has expired")
        }
        switch plan.request.action {
        case .tidy:
            guard let confirmation = tidyConfirmations.removeValue(forKey: plan.id) else {
                throw BridgeError.managerFailure(code: "plan-stale", detail: nil)
            }
            return try await executeTidy(plan, confirmation: confirmation, managerDirectory: managerDirectory)
        case .setPlugins, .switchTheme:
            return try await executeZshrcUpdate(plan, managerDirectory: managerDirectory)
        case .installPlugin:
            return try await executePlugin(plan, managerDirectory: managerDirectory)
        case .installOhMyZsh:
            var environment = environmentResolver.environment()
            environment["SHELL_MANAGER_ALLOW_JSON_EXECUTE"] = "1"
            return try await request(
                "execute",
                arguments: [plan.request.action.rawValue, plan.request.subject, plan.payload.planToken],
                managerDirectory: managerDirectory,
                environment: environment,
                timeout: executionTimeout,
                execution: plan.request
            )
        }
    }

    // MARK: - Direct Standard .zshrc & setup-zsh.sh Operations

    private func executeZshrcUpdate(_ plan: ShellActionPlan, managerDirectory: URL) async throws -> ShellOperationResult {
        let currentPlan = try await self.plan(plan.request, managerDirectory: managerDirectory)
        guard currentPlan.canExecute, currentPlan.payload.planToken == plan.payload.planToken else {
            throw BridgeError.managerFailure(code: "plan-stale", detail: nil)
        }
        let original = try ShellConfigurationFile.read(at: zshrcURL)
        let updated = try Self.applyZshrcUpdate(original.contents, request: plan.request)
        let backupURL = try createBackup(of: original.contents, named: ".zshrc")
        try writeRegularFile(updated, to: zshrcURL, replacing: original)
        let written = try ShellConfigurationFile.read(at: zshrcURL)
        do {
            try await validateZshSyntax(at: zshrcURL, directory: managerDirectory)
        } catch {
            try original.restore(at: zshrcURL, replacing: written.contents, matching: written)
            let detail = [String(localized: "Shell syntax validation failed. The previous configuration was restored."), error.localizedDescription].joined(separator: "\n")
            throw BridgeError.managerFailure(code: "shell-syntax-restored", detail: detail)
        }
        return ShellOperationResult(
            operationId: UUID().uuidString,
            action: plan.request.action.rawValue,
            subject: plan.request.subject,
            status: "ok",
            exitCode: 0,
            logFile: "",
            backupPath: backupURL.path
        )
    }

    private func executeTidy(_ plan: ShellActionPlan, confirmation: TidyConfirmation, managerDirectory: URL) async throws -> ShellOperationResult {
        let currentDiscovery = try discoverTidyCandidates()
        let currentZshenv = try readOptionalConfigurationFile(at: zshenvURL, symlinkCode: "zshenv-is-symlink")
        let currentZshrc = try readOptionalConfigurationFile(at: zshrcURL, symlinkCode: "zshrc-not-regular-file")
        guard currentDiscovery.staleCompdumps == confirmation.staleCompdumps,
              currentDiscovery.backupFiles == confirmation.backupFiles,
              filesMatch(confirmation.zshenv, currentZshenv),
              filesMatch(confirmation.zshrc, currentZshrc) else {
            throw BridgeError.managerFailure(code: "plan-stale", detail: nil)
        }

        try ensureDirectory(backupDirectoryURL)
        try ensureDirectory(cacheDirectoryURL)

        var backupPath = ""
        var changedPaths: [String] = []

        // 1. Keep ZSH_COMPDUMP in ~/.zshenv (matching setup-zsh.sh).
        let updatedZshenv = try Self.updatedZshenvForTidy(currentZshenv?.contents)
        if currentZshenv?.contents != updatedZshenv {
            if let currentZshenv {
                let saved = try createBackup(of: currentZshenv.contents, named: ".zshenv")
                backupPath = saved.path
                try writeRegularFile(updatedZshenv, to: zshenvURL, replacing: currentZshenv)
            } else {
                try createNewRegularFile(updatedZshenv, at: zshenvURL)
            }
            let written = try ShellConfigurationFile.read(at: zshenvURL)
            do {
                try await validateZshSyntax(at: zshenvURL, directory: managerDirectory)
                changedPaths.append(zshenvURL.path)
            } catch {
                if let currentZshenv {
                    try currentZshenv.restore(at: zshenvURL, replacing: written.contents, matching: written)
                } else {
                    try? FileManager.default.removeItem(at: zshenvURL)
                }
                let detail = [String(localized: "Shell syntax validation failed. The previous configuration was restored."), error.localizedDescription].joined(separator: "\n")
                throw BridgeError.managerFailure(code: "shell-syntax-restored", detail: detail)
            }
        }

        // 2. Remove legacy ZSH_COMPDUMP lines or managed compdump block from ~/.zshrc if present.
        if let currentZshrc {
            let cleanedZshrc = try Self.cleanedZshrcForTidy(currentZshrc.contents)
            if cleanedZshrc != currentZshrc.contents {
                do {
                    let saved = try createBackup(of: currentZshrc.contents, named: ".zshrc")
                    backupPath = saved.path
                    try writeRegularFile(cleanedZshrc, to: zshrcURL, replacing: currentZshrc)
                    let written = try ShellConfigurationFile.read(at: zshrcURL)
                    do {
                        try await validateZshSyntax(at: zshrcURL, directory: managerDirectory)
                        changedPaths.append(zshrcURL.path)
                    } catch {
                        try currentZshrc.restore(at: zshrcURL, replacing: written.contents, matching: written)
                        var failure = ShellExecutionFailure(
                            operation: nil,
                            cause: BridgeError.managerFailure(code: "shell-syntax-restored", detail: error.localizedDescription),
                            outcome: changedPaths.isEmpty ? .failed : .partiallySucceeded,
                            movedPaths: changedPaths
                        )
                        failure.verificationError = String(localized: "Shell syntax validation failed. The previous configuration was restored.")
                        throw failure
                    }
                } catch let failure as ShellExecutionFailure {
                    throw failure
                } catch {
                    throw ShellExecutionFailure(
                        operation: nil,
                        cause: error,
                        outcome: changedPaths.isEmpty ? (error is CancellationError ? .cancelled : .failed) : .partiallySucceeded,
                        movedPaths: changedPaths
                    )
                }
            }
        }

        // 3. Remove stale completion dump files in old locations (rebuilt automatically by zsh).
        for path in confirmation.staleCompdumps {
            do {
                try Task.checkCancellation()
                let fileURL = URL(filePath: path)
                try requireRegularFile(at: fileURL, code: "tidy-nonregular-candidate")
                try FileManager.default.removeItem(at: fileURL)
                changedPaths.append(path)
            } catch {
                throw ShellExecutionFailure(
                    operation: nil,
                    cause: error,
                    outcome: changedPaths.isEmpty ? (error is CancellationError ? .cancelled : .failed) : .partiallySucceeded,
                    movedPaths: changedPaths
                )
            }
        }

        // 4. Move historical backups into ~/.zsh/backups (skipping collisions without overwriting).
        for path in confirmation.backupFiles {
            do {
                try Task.checkCancellation()
                let sourceURL = URL(filePath: path)
                try requireRegularFile(at: sourceURL, code: "tidy-nonregular-candidate")
                let destinationURL = backupDirectoryURL.appending(path: sourceURL.lastPathComponent)
                if pathExistsNoFollow(at: destinationURL) { continue }
                try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
                changedPaths.append(destinationURL.path)
            } catch {
                throw ShellExecutionFailure(
                    operation: nil,
                    cause: error,
                    outcome: changedPaths.isEmpty ? (error is CancellationError ? .cancelled : .failed) : .partiallySucceeded,
                    movedPaths: changedPaths
                )
            }
        }

        return ShellOperationResult(
            operationId: UUID().uuidString,
            action: plan.request.action.rawValue,
            subject: plan.request.subject,
            status: "ok",
            exitCode: 0,
            logFile: "",
            backupPath: backupPath
        )
    }

    private func executePlugin(_ plan: ShellActionPlan, managerDirectory: URL) async throws -> ShellOperationResult {
        guard let url = TerminalPluginSource.repository(plan.request.subject) else {
            throw BridgeError.managerFailure(code: "invalid-plugin-url", detail: nil)
        }
        let original = try ShellConfigurationFile.read(at: zshrcURL)
        let snapshot = try await loadSnapshot(managerDirectory: managerDirectory, managerAvailable: true)
        let installed = Set(snapshot.defaultPluginNames + snapshot.installedCustomPlugins)
        var plugins = snapshot.activePlugins.filter { installed.contains($0) }
        for name in ["git", url.lastPathComponent] where !plugins.contains(name) { plugins.append(name) }
        let staging = try ShellPluginStaging(home: homeURL)
        var environment = environmentResolver.environment()
        environment["SHELL_MANAGER_ALLOW_JSON_EXECUTE"] = "1"
        environment["SHELL_MANAGER_PLUGIN_STAGING"] = staging.directory.path
        environment["SHELL_MANAGER_PLUGIN_OWNER"] = staging.token
        environment["SHELL_MANAGER_PLUGIN_IDENTITY"] = staging.identity
        let operation: ShellOperationResult
        var cloned: ShellOperationResult?
        do {
            operation = try await request(
                "execute",
                arguments: [plan.request.action.rawValue, plan.request.subject, plan.payload.planToken],
                managerDirectory: managerDirectory,
                environment: environment,
                timeout: executionTimeout,
                execution: plan.request
            )
            cloned = operation
            await beforePluginPublication()
            try Task.checkCancellation()
            guard original.matches(try ShellConfigurationFile.read(at: zshrcURL)) else {
                throw BridgeError.managerFailure(code: "plan-stale", detail: nil)
            }
            try staging.publish(name: url.lastPathComponent)
        } catch {
            let evidence = (error as? ShellExecutionFailure) ?? cloned.map { ShellExecutionFailure(operation: $0, cause: error) }
            do { try staging.cleanup() }
            catch {
                if var evidence {
                    evidence.verificationError = error.localizedDescription
                    throw evidence
                }
                throw error
            }
            if var evidence {
                evidence.outcome = evidence.cause is CancellationError ? .cancelled : .failed
                throw evidence
            }
            throw error
        }
        do {
            try staging.cleanup()
            try staging.verifyPublished(name: url.lastPathComponent)
            let selection = try await self.plan(.init(action: .setPlugins, subject: plugins.joined(separator: ",")), managerDirectory: managerDirectory)
            guard original.matches(try ShellConfigurationFile.read(at: zshrcURL)) else {
                throw BridgeError.managerFailure(code: "plan-stale", detail: nil)
            }
            try staging.verifyPublished(name: url.lastPathComponent)
            _ = try await executeZshrcUpdate(selection, managerDirectory: managerDirectory)
            return operation
        } catch {
            // The cloned plugin is already published; never delete it or claim rollback.
            return .init(
                operationId: operation.operationId,
                action: operation.action,
                subject: operation.subject,
                status: "partial",
                exitCode: operation.exitCode,
                logFile: operation.logFile,
                backupPath: operation.backupPath,
                detail: (error as? ShellExecutionFailure)?.diagnosticDetail ?? error.localizedDescription
            )
        }
    }
}

private struct TidyConfirmation {
    let staleCompdumps: [String]
    let backupFiles: [String]
    let zshenv: ShellConfigurationFile?
    let zshrc: ShellConfigurationFile?
}
