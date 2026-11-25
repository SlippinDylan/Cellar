import Darwin
import Foundation

extension ShellManagerClient {
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

    var homeURL: URL {
        guard let home = environmentResolver.environment()["HOME"] else {
            preconditionFailure("Shell environment requires HOME")
        }
        return URL(filePath: home)
    }

    var zshrcURL: URL { homeURL.appending(path: ".zshrc") }
    var zshenvURL: URL { homeURL.appending(path: ".zshenv") }
    private var zshDirectoryURL: URL { homeURL.appending(path: ".zsh") }
    var backupDirectoryURL: URL { zshDirectoryURL.appending(path: "backups") }
    var cacheDirectoryURL: URL { homeURL.appending(path: ".cache/zsh") }

    func regularZshrcContents() throws -> Data {
        try ShellConfigurationFile.read(at: zshrcURL).contents
    }

    func readOptionalConfigurationFile(at url: URL, symlinkCode: String) throws -> ShellConfigurationFile? {
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

    func filesMatch(_ lhs: ShellConfigurationFile?, _ rhs: ShellConfigurationFile?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (a?, b?): return a.matches(b)
        default: return false
        }
    }

    func requireRegularFile(at url: URL, code: String) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw BridgeError.managerFailure(code: code, detail: nil)
        }
    }

    func pathExistsNoFollow(at url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0
    }

    func ensureDirectory(_ url: URL) throws {
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

    func createBackup(of contents: Data, named prefix: String) throws -> URL {
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

    func writeRegularFile(_ data: Data, to url: URL, replacing expected: ShellConfigurationFile) throws {
        try expected.replacingContents(data).restore(at: url, replacing: expected.contents, matching: expected)
    }

    func createNewRegularFile(_ data: Data, at url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw BridgeError.managerFailure(code: "shell-restore-state-changed", detail: nil)
        }
        defer { close(fd) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: data)
    }

    func validateZshSyntax(at fileURL: URL, directory: URL) async throws {
        let validation = Task { try await self.validateSyntax(fileURL, directory) }
        let exitCode = try await validation.value
        guard exitCode == 0 else {
            throw BridgeError.managerFailure(code: "shell-syntax-invalid", detail: "exitCode=\(exitCode)")
        }
    }

    func discoverTidyCandidates() throws -> TidyDiscovery {
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

    func builtInPlugins(at root: URL, installed: Bool) throws -> [String] {
        guard installed else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root.appending(path: "plugins"), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
            .map(\.lastPathComponent).sorted()
    }

    func request<Payload: Decodable & Sendable>(
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

struct TidyDiscovery {
    let staleCompdumps: [String]
    let backupFiles: [String]
    var allPaths: [String] { staleCompdumps + backupFiles }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
