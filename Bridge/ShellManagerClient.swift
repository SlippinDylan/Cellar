import Darwin
import Foundation

actor ShellManagerClient {
    static let compdumpComment = "# Zsh completion dump location"
    static let compdumpSetting = #"export ZSH_COMPDUMP="$HOME/.cache/zsh/.zcompdump-$HOST""#

    private let runner: ProcessRunner
    private let environmentResolver: ShellEnvironmentResolver
    private let executionTimeout: Duration
    private let beforePluginPublication: @Sendable () async -> Void
    private let validateSyntax: @Sendable (URL, URL) async throws -> Int32
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

    // MARK: - Pure Configuration File Transformations

    static func applyZshrcUpdate(_ contents: Data, request: ShellActionRequest) throws -> Data {
        guard let text = String(data: contents, encoding: .utf8) else {
            throw BridgeError.invalidOutput("Invalid UTF-8 shell configuration")
        }
        var lines = splitLines(text)
        switch request.action {
        case .setPlugins:
            let names = normalizedPluginNames(from: request.subject)
            let replacement = "plugins=(\(names.joined(separator: " ")))"
            lines = try removeManagedBlock(named: "plugins", from: lines)
            lines = try replaceOrInsertPlugins(replacement, in: lines)
        case .switchTheme:
            let replacement = "ZSH_THEME=\"\(request.subject)\""
            lines = try removeManagedBlock(named: "theme", from: lines)
            lines = replaceOrInsertTheme(replacement, in: lines)
        default:
            throw BridgeError.managerFailure(code: "unsupported-configuration", detail: nil)
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    static func updatedZshenvForTidy(_ existing: Data?) throws -> Data {
        let text: String
        if let existing {
            guard let decoded = String(data: existing, encoding: .utf8) else {
                throw BridgeError.invalidOutput("Invalid UTF-8 shell configuration")
            }
            text = decoded
        } else {
            text = ""
        }
        var lines = splitLines(text).filter { !isCompdumpConfigLine($0) }
        while lines.last == "" { lines.removeLast() }
        if !lines.isEmpty { lines.append("") }
        lines.append(compdumpComment)
        lines.append(compdumpSetting)
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    static func cleanedZshrcForTidy(_ contents: Data) throws -> Data {
        guard let text = String(data: contents, encoding: .utf8) else {
            throw BridgeError.invalidOutput("Invalid UTF-8 shell configuration")
        }
        var lines = splitLines(text)
        lines = try removeManagedBlock(named: "compdump", from: lines)
        lines = lines.filter { !isCompdumpConfigLine($0) }
        while lines.last == "" { lines.removeLast() }
        return lines.isEmpty ? Data() : Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private static func isCompdumpConfigLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == compdumpComment || trimmed.hasPrefix("export ZSH_COMPDUMP=") || trimmed.hasPrefix("ZSH_COMPDUMP=")
    }

    private static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let parts = text.components(separatedBy: "\n")
        return text.hasSuffix("\n") ? Array(parts.dropLast()) : parts
    }

    private static func normalizedPluginNames(from csv: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in csv.split(separator: ",") {
            let name = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, seen.insert(name).inserted { result.append(name) }
        }
        if !seen.contains("git") { result.insert("git", at: 0) }
        return result
    }

    private static func removeManagedBlock(named kind: String, from lines: [String]) throws -> [String] {
        let start = "# >>> omz-manager \(kind) >>>"
        let end = "# <<< omz-manager \(kind) <<<"
        var output: [String] = []
        var skipping = false
        for line in lines {
            if line == start {
                guard !skipping else { throw BridgeError.managerFailure(code: "invalid-managed-block", detail: nil) }
                skipping = true
            } else if line == end {
                guard skipping else { throw BridgeError.managerFailure(code: "invalid-managed-block", detail: nil) }
                skipping = false
            } else if !skipping {
                output.append(line)
            }
        }
        guard !skipping else { throw BridgeError.managerFailure(code: "invalid-managed-block", detail: nil) }
        return output
    }

    private static func ohMyZshSourceIndex(in lines: [String]) -> Int? {
        lines.firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { return false }
            return trimmed.contains("oh-my-zsh.sh") && (trimmed.hasPrefix("source ") || trimmed.hasPrefix(". "))
        }
    }

    private static func replaceOrInsertTheme(_ replacement: String, in lines: [String]) -> [String] {
        var result = lines
        // Zsh evaluates the last assignment, so update the last active ZSH_THEME line.
        if let index = result.lastIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("#") && (trimmed.hasPrefix("ZSH_THEME=") || trimmed.hasPrefix("export ZSH_THEME="))
        }) {
            result[index] = replacement
            return result
        }
        if let sourceIndex = ohMyZshSourceIndex(in: result) {
            result.insert(replacement, at: sourceIndex)
        } else {
            result.append(replacement)
        }
        return result
    }

    private static func replaceOrInsertPlugins(_ replacement: String, in lines: [String]) throws -> [String] {
        var result = lines
        if let startIndex = result.lastIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), trimmed.hasPrefix("plugins=") else { return false }
            let afterEquals = trimmed.dropFirst("plugins=".count).trimmingCharacters(in: .whitespaces)
            return afterEquals.hasPrefix("(")
        }) {
            var endIndex: Int?
            for idx in startIndex..<result.count {
                let code = result[idx].split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                if code.contains(")") {
                    endIndex = idx
                    break
                }
            }
            guard let endIndex else {
                throw BridgeError.managerFailure(code: "shell-init-ambiguous", detail: "Unterminated plugins=( declaration in .zshrc")
            }
            result.replaceSubrange(startIndex...endIndex, with: [replacement])
            return result
        }
        if let sourceIndex = ohMyZshSourceIndex(in: result) {
            result.insert(replacement, at: sourceIndex)
        } else {
            result.append(replacement)
        }
        return result
    }

    // MARK: - Filesystem & Validation Helpers

    private var homeURL: URL {
        guard let home = environmentResolver.environment()["HOME"] else {
            preconditionFailure("Shell environment requires HOME")
        }
        return URL(filePath: home)
    }

    private var zshrcURL: URL { homeURL.appending(path: ".zshrc") }
    private var zshenvURL: URL { homeURL.appending(path: ".zshenv") }
    private var zshDirectoryURL: URL { homeURL.appending(path: ".zsh") }
    private var backupDirectoryURL: URL { zshDirectoryURL.appending(path: "backups") }
    private var cacheDirectoryURL: URL { homeURL.appending(path: ".cache/zsh") }

    private func regularZshrcContents() throws -> Data {
        try ShellConfigurationFile.read(at: zshrcURL).contents
    }

    private func readOptionalConfigurationFile(at url: URL, symlinkCode: String) throws -> ShellConfigurationFile? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw BridgeError.managerFailure(code: symlinkCode, detail: nil)
        }
        return try ShellConfigurationFile.read(at: url)
    }

    private func filesMatch(_ lhs: ShellConfigurationFile?, _ rhs: ShellConfigurationFile?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (a?, b?): return a.matches(b)
        default: return false
        }
    }

    private func requireRegularFile(at url: URL, code: String) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw BridgeError.managerFailure(code: code, detail: nil)
        }
    }

    private func pathExistsNoFollow(at url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0
    }

    private func ensureDirectory(_ url: URL) throws {
        // Verify each ancestor under HOME is a real directory, never traversing a symlink.
        let homePath = homeURL.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        if targetPath.hasPrefix(homePath + "/") {
            let relative = String(targetPath.dropFirst(homePath.count + 1))
            var cursor = homeURL
            for component in relative.split(separator: "/") {
                cursor = cursor.appending(path: String(component))
                var metadata = stat()
                if lstat(cursor.path, &metadata) == 0 {
                    guard metadata.st_mode & S_IFMT == S_IFDIR else {
                        throw BridgeError.managerFailure(code: "tidy-unsafe-destination", detail: nil)
                    }
                } else if errno == ENOENT {
                    try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: false)
                } else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            return
        }
        var metadata = stat()
        if lstat(url.path, &metadata) == 0 {
            guard metadata.st_mode & S_IFMT == S_IFDIR else {
                throw BridgeError.managerFailure(code: "tidy-unsafe-destination", detail: nil)
            }
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func createBackup(of contents: Data, named prefix: String) throws -> URL {
        try ensureDirectory(backupDirectoryURL)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let baseName = "\(prefix).backup-\(formatter.string(from: Date()))"
        var candidate = backupDirectoryURL.appending(path: baseName)
        var suffix = 1
        while pathExistsNoFollow(at: candidate) {
            candidate = backupDirectoryURL.appending(path: "\(baseName)-\(suffix)")
            suffix += 1
        }
        try contents.write(to: candidate, options: .atomic)
        return candidate
    }

    private func writeRegularFile(_ data: Data, to url: URL, replacing expected: ShellConfigurationFile) throws {
        try expected.replacingContents(data).restore(at: url, replacing: expected.contents, matching: expected)
    }

    private func createNewRegularFile(_ data: Data, at url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw BridgeError.managerFailure(code: "shell-restore-state-changed", detail: nil)
        }
        defer { close(fd) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: data)
    }

    private func validateZshSyntax(at fileURL: URL, directory: URL) async throws {
        let validation = Task { try await self.validateSyntax(fileURL, directory) }
        let exitCode = try await validation.value
        guard exitCode == 0 else {
            throw BridgeError.managerFailure(code: "shell-syntax-invalid", detail: "exitCode=\(exitCode)")
        }
    }

    private func discoverTidyCandidates() throws -> TidyDiscovery {
        for directory in [zshDirectoryURL, backupDirectoryURL, homeURL.appending(path: ".cache"), cacheDirectoryURL] {
            var metadata = stat()
            if lstat(directory.path, &metadata) == 0 {
                guard metadata.st_mode & S_IFMT == S_IFDIR else {
                    throw BridgeError.managerFailure(code: "tidy-unsafe-destination", detail: nil)
                }
            } else if errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        var staleCompdumps: [String] = []
        var backupFiles: [String] = []

        for file in try FileManager.default.contentsOfDirectory(at: homeURL, includingPropertiesForKeys: nil) {
            let name = file.lastPathComponent
            if name.hasPrefix(".zcompdump") {
                try requireRegularFile(at: file, code: "tidy-nonregular-candidate")
                staleCompdumps.append(file.path)
            } else if name.hasPrefix(".zshrc.backup-") || name.hasPrefix(".zshrc.backup.")
                || name == ".zprofile.bak" || name.hasPrefix(".zprofile.backup-") || name.hasPrefix(".zprofile.backup.") {
                try requireRegularFile(at: file, code: "tidy-nonregular-candidate")
                let target = backupDirectoryURL.appending(path: name)
                if !pathExistsNoFollow(at: target) {
                    backupFiles.append(file.path)
                }
            }
        }

        if FileManager.default.fileExists(atPath: zshDirectoryURL.path) {
            for file in try FileManager.default.contentsOfDirectory(at: zshDirectoryURL, includingPropertiesForKeys: nil) {
                let name = file.lastPathComponent
                if name.hasPrefix("zcompdump") || name.hasPrefix(".zcompdump") {
                    try requireRegularFile(at: file, code: "tidy-nonregular-candidate")
                    staleCompdumps.append(file.path)
                }
            }
        }

        return TidyDiscovery(
            staleCompdumps: staleCompdumps.sorted(),
            backupFiles: backupFiles.sorted()
        )
    }

    private func builtInPlugins(at root: URL, installed: Bool) throws -> [String] {
        guard installed else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root.appending(path: "plugins"), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
            .map(\.lastPathComponent).sorted()
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
        guard !result.standardOutputWasTruncated, !result.standardErrorWasTruncated else {
            throw BridgeError.invalidOutput("Shell Manager output exceeded the safety limit")
        }
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

private struct TidyDiscovery {
    let staleCompdumps: [String]
    let backupFiles: [String]
    var allPaths: [String] { staleCompdumps + backupFiles }
}

private struct TidyConfirmation {
    let staleCompdumps: [String]
    let backupFiles: [String]
    let zshenv: ShellConfigurationFile?
    let zshrc: ShellConfigurationFile?
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
