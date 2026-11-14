import Darwin
import Foundation

actor ShellManagerClient {
    private let runner: ProcessRunner
    private let environmentResolver: ShellEnvironmentResolver
    private let executionTimeout: Duration
    private let beforePluginPublication: @Sendable () async -> Void
    private let validateSyntax: @Sendable (URL, URL) async throws -> Int32
    private var consumedConfigurations = Set<UUID>()
    private var tidyConfirmations: [UUID: (candidates: [String], file: ShellConfigurationFile)] = [:]

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
        if plan.canExecute, request.action != .installOhMyZsh {
            _ = try Self.relocateManagedBlocks(regularZshrcContents())
        }
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
            let evidence = error as? ShellExecutionFailure
            if let operation = evidence?.operation { operations.append(operation) }
            let cancelled = error is CancellationError || Task.isCancelled
            if let index = activeStep {
                outcomes[index] = .init(step: outcomes[index].step, status: evidence?.outcome.itemStatus ?? (outcomes[index].status == .succeeded ? .partiallySucceeded : cancelled ? .cancelled : .failed))
            }
            if cancelled {
                outcomes = outcomes.enumerated().map { index, outcome in
                    outcome.status == .unknown && index != activeStep ? .init(step: outcome.step, status: .cancelled) : outcome
                }
            }
            return .init(operations: operations, failure: evidence?.diagnosticDetail ?? error.localizedDescription, wasCancelled: cancelled, stepOutcomes: outcomes, failureReason: evidence?.reason ?? .init(error: error))
        }
    }

    private func regularZshrcContents() throws -> Data {
        try ShellConfigurationFile.read(at: zshrcURL).contents
    }

    private var zshrcURL: URL {
        guard let home = environmentResolver.environment()["HOME"] else { preconditionFailure("Shell environment requires HOME") }
        return URL(filePath: home).appending(path: ".zshrc")
    }

    static func expectedConfiguration(_ contents: Data, request: ShellActionRequest) throws -> Data {
        try relocateManagedBlocks(adapterConfiguration(contents, request: request))
    }

    // Verify the frozen writer's exact output before relocating its managed blocks.
    static func adapterConfiguration(_ contents: Data, request: ShellActionRequest) throws -> Data {
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

    static func relocateManagedBlocks(_ contents: Data) throws -> Data {
        guard let text = String(data: contents, encoding: .utf8) else { throw BridgeError.invalidOutput("Invalid UTF-8 shell configuration") }
        let sources: Set<String> = ["source $ZSH/oh-my-zsh.sh", "source \"$ZSH/oh-my-zsh.sh\"", "source \"${ZSH}/oh-my-zsh.sh\"", ". \"$ZSH/oh-my-zsh.sh\""]
        var body: [String] = []
        var blocks: [String] = []
        var block: String?
        var seen = Set<String>()
        var sourceIndex: Int?
        for line in text.components(separatedBy: "\n").dropLast(text.hasSuffix("\n") ? 1 : 0) {
            if line.hasPrefix("# >>> omz-manager ") {
                guard block == nil, ["plugins", "theme", "compdump"].contains(where: { line == "# >>> omz-manager \($0) >>>" }), seen.insert(line).inserted else {
                    throw BridgeError.managerFailure(code: "invalid-managed-block", detail: nil)
                }
                block = line.replacingOccurrences(of: ">>>", with: "<<<")
                blocks.append(line)
            } else if let end = block {
                guard line.trimmingCharacters(in: .whitespaces).hasPrefix("#") || !line.contains("oh-my-zsh.sh") else {
                    throw BridgeError.managerFailure(code: "shell-init-ambiguous", detail: nil)
                }
                blocks.append(line)
                if line == end { block = nil }
            } else {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.hasPrefix("#"), trimmed.contains("oh-my-zsh.sh") {
                    guard sources.contains(trimmed), sourceIndex == nil else { throw BridgeError.managerFailure(code: "shell-init-ambiguous", detail: nil) }
                    sourceIndex = body.count
                } else if sourceIndex == nil, !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                    // Only complete assignment lines before initialization are supported. This
                    // excludes conditional loaders, functions, continuations and quoted fake sources.
                    guard trimmed.range(of: #"^(export )?[A-Za-z_][A-Za-z0-9_]*=[^;`\\&|<>]*$"#, options: .regularExpression) != nil,
                          !trimmed.contains("$("), !trimmed.contains("<<"),
                          trimmed.filter({ $0 == "\"" }).count.isMultiple(of: 2),
                          trimmed.filter({ $0 == "'" }).count.isMultiple(of: 2),
                          trimmed.filter({ $0 == "(" }).count == trimmed.filter({ $0 == ")" }).count else {
                        throw BridgeError.managerFailure(code: "shell-init-ambiguous", detail: nil)
                    }
                }
                body.append(line)
            }
        }
        guard block == nil, let sourceIndex else { throw BridgeError.managerFailure(code: "shell-init-unavailable", detail: nil) }
        body.insert(contentsOf: blocks, at: sourceIndex)
        return Data((body.joined(separator: "\n") + "\n").utf8)
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
        if plan.request.action == .installPlugin {
            return try await executePlugin(plan, managerDirectory: managerDirectory)
        }
        var environment = environmentResolver.environment()
        environment["SHELL_MANAGER_ALLOW_JSON_EXECUTE"] = "1"
        let original = [.setPlugins, .switchTheme].contains(plan.request.action) ? try ShellConfigurationFile.read(at: zshrcURL) : nil
        if let original { _ = try Self.expectedConfiguration(original.contents, request: plan.request) }
        var completed: ShellOperationResult?
        do {
            let operation: ShellOperationResult = try await request(
                "execute", arguments: [plan.request.action.rawValue, plan.request.subject, plan.payload.planToken],
                managerDirectory: managerDirectory, environment: environment, timeout: executionTimeout, execution: plan.request
            )
            completed = operation
            if let original { try await finishConfiguration(original: original, request: plan.request, managerDirectory: managerDirectory) }
            return operation
        } catch {
            var evidence = (error as? ShellExecutionFailure) ?? completed.map { ShellExecutionFailure(operation: $0, cause: error) }
            if original != nil, Self.isExecutionInterruption(error) { evidence = .init(operation: nil, cause: error) }
            if case BridgeError.managerFailure(code: "shell-syntax-restored", detail: _) = error {
                evidence?.outcome = .failed
            } else if let original, evidence != nil {
                do {
                    if completed == nil, (try regularZshrcContents()) == (try Self.adapterConfiguration(original.contents, request: plan.request)) {
                        try await finishConfiguration(original: original, request: plan.request, managerDirectory: managerDirectory)
                        evidence?.outcome = .partiallySucceeded
                    } else if original.matches(try ShellConfigurationFile.read(at: zshrcURL)) {
                        evidence?.outcome = error is CancellationError ? .cancelled : .failed
                    }
                } catch {
                    if var evidence {
                        evidence.verificationError = error.localizedDescription
                        // A verified restore retains the writer's new inode, not the original inode.
                        if case BridgeError.managerFailure(code: "shell-syntax-restored", detail: _) = error {
                            evidence.outcome = .failed
                        } else {
                            do { evidence.outcome = original.matches(try ShellConfigurationFile.read(at: zshrcURL)) ? .failed : .unknown }
                            catch { evidence.verificationError = [evidence.verificationError ?? "", error.localizedDescription].joined(separator: "\n") }
                        }
                        throw evidence
                    }
                    throw error
                }
            }
            if let evidence { throw evidence }
            throw error
        }
    }

    private func executePlugin(_ plan: ShellActionPlan, managerDirectory: URL) async throws -> ShellOperationResult {
        guard let url = TerminalPluginSource.repository(plan.request.subject) else { throw BridgeError.managerFailure(code: "invalid-plugin-url", detail: nil) }
        let original = try ShellConfigurationFile.read(at: zshrcURL)
        _ = try Self.relocateManagedBlocks(original.contents)
        let snapshot = try await loadSnapshot(managerDirectory: managerDirectory, managerAvailable: true)
        let installed = Set(snapshot.defaultPluginNames + snapshot.installedCustomPlugins)
        var plugins = snapshot.activePlugins.filter { installed.contains($0) }
        for name in ["git", url.lastPathComponent] where !plugins.contains(name) { plugins.append(name) }
        let staging = try ShellPluginStaging(home: zshrcURL.deletingLastPathComponent())
        var environment = environmentResolver.environment()
        environment["SHELL_MANAGER_ALLOW_JSON_EXECUTE"] = "1"
        environment["SHELL_MANAGER_PLUGIN_STAGING"] = staging.directory.path
        environment["SHELL_MANAGER_PLUGIN_OWNER"] = staging.token
        environment["SHELL_MANAGER_PLUGIN_IDENTITY"] = staging.identity
        let operation: ShellOperationResult
        var cloned: ShellOperationResult?
        do {
            operation = try await request("execute", arguments: [plan.request.action.rawValue, plan.request.subject, plan.payload.planToken],
                managerDirectory: managerDirectory, environment: environment, timeout: executionTimeout, execution: plan.request)
            cloned = operation
            await beforePluginPublication()
            try Task.checkCancellation()
            guard original.matches(try ShellConfigurationFile.read(at: zshrcURL)) else { throw BridgeError.managerFailure(code: "plan-stale", detail: nil) }
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
            guard original.matches(try ShellConfigurationFile.read(at: zshrcURL)) else { throw BridgeError.managerFailure(code: "plan-stale", detail: nil) }
            try staging.verifyPublished(name: url.lastPathComponent)
            _ = try await execute(selection, managerDirectory: managerDirectory)
            return operation
        } catch {
            // The cloned plugin is already published; never delete it or claim rollback.
            return .init(operationId: operation.operationId, action: operation.action, subject: operation.subject, status: "partial", exitCode: operation.exitCode,
                         logFile: operation.logFile, backupPath: operation.backupPath, detail: (error as? ShellExecutionFailure)?.diagnosticDetail ?? error.localizedDescription)
        }
    }

    private func relocateConfiguration(original: ShellConfigurationFile, request: ShellActionRequest) throws -> ShellConfigurationFile {
        let produced = try Self.adapterConfiguration(original.contents, request: request)
        let expected = try Self.expectedConfiguration(original.contents, request: request)
        let current = try ShellConfigurationFile.read(at: zshrcURL)
        guard current.contents == produced else { throw BridgeError.managerFailure(code: "shell-restore-state-changed", detail: nil) }
        try current.replacingContents(expected).restore(at: zshrcURL, replacing: produced, matching: current)
        return try ShellConfigurationFile.read(at: zshrcURL)
    }

    private func finishConfiguration(original: ShellConfigurationFile, request: ShellActionRequest, managerDirectory: URL) async throws {
        let relocated = try relocateConfiguration(original: original, request: request)
        // Completing validation/rollback is mandatory even when the adapter was cancelled.
        let validation = Task { try await self.validateSyntax(self.zshrcURL, managerDirectory) }
        let validationFailure: (any Error)?
        do {
            let exitCode = try await validation.value
            validationFailure = exitCode == 0 ? nil : BridgeError.managerFailure(code: "shell-syntax-invalid", detail: "exitCode=\(exitCode)")
        } catch { validationFailure = error }
        if let validationFailure {
            try original.restore(at: zshrcURL, replacing: relocated.contents, matching: relocated)
            let detail = [String(localized: "Shell syntax validation failed. The previous configuration was restored."), validationFailure.localizedDescription].joined(separator: "\n")
            throw BridgeError.managerFailure(code: "shell-syntax-restored", detail: detail)
        }
        guard relocated.matches(try ShellConfigurationFile.read(at: zshrcURL)) else { throw BridgeError.managerFailure(code: "shell-restore-state-changed", detail: nil) }
    }

    private func executeTidy(_ plan: ShellActionPlan, original: ShellConfigurationFile, managerDirectory: URL) async throws -> ShellOperationResult {
        let expected = try Self.expectedConfiguration(original.contents, request: plan.request)
        var environment = environmentResolver.environment()
        environment["SHELL_MANAGER_ALLOW_JSON_EXECUTE"] = "1"
        let files = try plan.candidates.map { path in (URL(filePath: path), try TidyFileIdentity.read(at: URL(filePath: path))) }
        let operation: ShellOperationResult
        do {
            operation = try await request("execute", arguments: [plan.request.action.rawValue, plan.request.subject, plan.payload.planToken],
                                         managerDirectory: managerDirectory, environment: environment, timeout: executionTimeout, execution: plan.request)
        } catch {
            // Only actual execution failures and interruptions can have postflight changes.
            let interrupted = Self.isExecutionInterruption(error)
            guard error is ShellExecutionFailure || interrupted else { throw error }
            throw observeTidyFailure((error as? ShellExecutionFailure) ?? .init(operation: nil, cause: error), files: files, original: original)
        }
        do {
            let current = try relocateConfiguration(original: original, request: plan.request)
            let validationFailure: (any Error)?
            do {
                let exitCode = try await validateSyntax(zshrcURL, managerDirectory)
                validationFailure = exitCode == 0 ? nil : BridgeError.managerFailure(code: "shell-syntax-invalid", detail: "exitCode=\(exitCode)")
            } catch { validationFailure = error }
            if let validationFailure {
                try original.restore(at: zshrcURL, replacing: expected, matching: current)
                var failure = observeTidyFailure(.init(operation: operation, cause: validationFailure), files: files, original: original, configurationRestored: true)
                failure.verificationError = String(localized: "Shell syntax validation failed. The previous configuration was restored.")
                guard failure.outcome == .partiallySucceeded else { throw failure }
                return .init(operationId: operation.operationId, action: operation.action, subject: operation.subject, status: "partial", exitCode: operation.exitCode,
                             logFile: operation.logFile, backupPath: operation.backupPath, detail: failure.diagnosticDetail)
            }
            return operation
        } catch {
            if error is ShellExecutionFailure { throw error }
            let failure = observeTidyFailure(.init(operation: operation, cause: error), files: files, original: original)
            guard failure.outcome == .partiallySucceeded else { throw failure }
            return .init(operationId: operation.operationId, action: operation.action, subject: operation.subject, status: "partial", exitCode: operation.exitCode,
                         logFile: operation.logFile, backupPath: operation.backupPath, detail: failure.diagnosticDetail)
        }
    }

    private func observeTidyFailure(_ failure: ShellExecutionFailure, files: [(URL, TidyFileIdentity)], original: ShellConfigurationFile,
                                    configurationRestored: Bool = false) -> ShellExecutionFailure {
        var evidence = failure
        var moved = false
        var unchanged = true
        for (source, identity) in files {
            let directory = source.lastPathComponent.hasPrefix(".zcompdump") ? ".zsh" : ".zsh/backups"
            let destination = source.deletingLastPathComponent().appending(path: directory).appending(path: source.lastPathComponent)
            do {
                let before = try TidyFileIdentity.readIfPresent(at: source)
                try TidyFileIdentity.validateDestination(home: source.deletingLastPathComponent(), backups: directory == ".zsh/backups")
                let after = try TidyFileIdentity.readIfPresent(at: destination)
                if before == nil, after == identity {
                    moved = true
                    evidence.movedPaths.append(destination.path)
                }
                if before != identity || after != nil { unchanged = false }
            } catch {
                unchanged = false
                evidence.verificationError = error.localizedDescription
            }
        }
        do {
            let current = try ShellConfigurationFile.read(at: zshrcURL)
            unchanged = unchanged && (configurationRestored ? current.contents == original.contents : original.matches(current))
        } catch {
            unchanged = false
            evidence.verificationError = error.localizedDescription
        }
        if moved { evidence.outcome = .partiallySucceeded }
        else if unchanged { evidence.outcome = failure.cause is CancellationError ? .cancelled : .failed }
        else { evidence.outcome = .unknown }
        return evidence
    }

    private static func isExecutionInterruption(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if case BridgeError.processTimedOut = error { return true }
        return false
    }

    private func request<Payload: Decodable & Sendable>(
        _ command: String,
        arguments: [String] = [],
        managerDirectory: URL,
        environment: [String: String],
        timeout: Duration? = .seconds(300),
        execution: ShellActionRequest? = nil
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
        if let execution, command == "execute", envelope.command == "execute", !envelope.ok,
           envelope.data == nil, result.terminationStatus != 0, envelope.error?.code == "action-failed" {
            let evidence: ShellExecutionErrorEnvelope
            do { evidence = try JSONDecoder().decode(ShellExecutionErrorEnvelope.self, from: result.standardOutput) }
            catch { throw BridgeError.invalidOutput(error.localizedDescription) }
            let operation = evidence.error.operation
            guard operation.action == execution.action.rawValue, operation.subject == execution.subject,
                  operation.status == "failed", operation.exitCode > 0,
                  !operation.operationId.isEmpty, !operation.logFile.isEmpty else {
                throw BridgeError.invalidOutput("Shell execution evidence does not match the request")
            }
            throw ShellExecutionFailure(operation: operation, cause: BridgeError.managerFailure(code: evidence.error.code, detail: envelope.error?.message))
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

private struct TidyFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    static func validateDestination(home: URL, backups: Bool) throws {
        for path in backups ? [".zsh", ".zsh/backups"] : [".zsh"] {
            var metadata = stat()
            guard lstat(home.appending(path: path).path, &metadata) == 0 else {
                if errno == ENOENT { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard metadata.st_mode & S_IFMT == S_IFDIR else { throw BridgeError.managerFailure(code: "tidy-unsafe-destination", detail: nil) }
        }
    }

    static func read(at url: URL) throws -> Self {
        guard let identity = try readIfPresent(at: url) else { throw BridgeError.managerFailure(code: "plan-stale", detail: nil) }
        return identity
    }

    static func readIfPresent(at url: URL) throws -> Self? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw BridgeError.managerFailure(code: "tidy-nonregular-candidate", detail: nil) }
        return Self(device: metadata.st_dev, inode: metadata.st_ino)
    }
}
