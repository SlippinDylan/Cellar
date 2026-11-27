import Foundation

enum HomebrewClientError: LocalizedError {
    case executableNotFound(String)
    case commandFailed(HomebrewCommandOutput)
    case invalidJSON(arguments: [String], detail: String)
    case invalidPlan(String)
    case stateChanged
    case scanIncomplete
    case alreadyInstalled(HomebrewPackageIdentity)
    case outputTruncated(arguments: [String])

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let path):
            "Homebrew executable not found: \(path)"
        case .commandFailed(let output):
            output.standardError.nilIfBlank
                ?? output.standardOutput.nilIfBlank
                ?? "brew \(output.arguments.joined(separator: " ")) failed (exit \(output.terminationStatus))"
        case .invalidJSON(_, let detail):
            "Homebrew returned unrecognized data: \(detail)"
        case .invalidPlan(let detail):
            detail
        case .stateChanged:
            String(localized: ActivityItemReason.stateChanged.message)
        case .scanIncomplete:
            String(localized: ActivityItemReason.scanIncomplete.message)
        case .alreadyInstalled(let identity):
            "Package is already installed: \(identity.name)"
        case .outputTruncated(let arguments):
            "Output from brew \(arguments.joined(separator: " ")) exceeded the safety limit"
        }
    }
}

actor HomebrewClient {
    private let brewURL: URL
    private let runner: ProcessRunner
    let environment: [String: String]
    let currentDirectoryURL: URL
    private let developerDirectoryProbeURL: URL
    let caskRemovalScanner: CaskRemovalScanner
    let caskRemovalAuthorizer: CaskRemovalAuthorizer?
    let caskApplicationLifecycle: CaskApplicationLifecycle
    private var mutationInProgress = false

    func withMutationLock<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        guard !mutationInProgress else {
            throw HomebrewClientError.invalidPlan("Another Homebrew write operation is already in progress")
        }
        mutationInProgress = true
        defer { mutationInProgress = false }
        return try await operation()
    }

    init(
        brewURL: URL,
        runner: ProcessRunner,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory,
        userName: String = NSUserName(),
        developerDirectoryProbeURL: URL = URL(filePath: "/usr/bin/xcode-select"),
        caskRemovalScanner: CaskRemovalScanner? = nil,
        caskRemovalAuthorizer: CaskRemovalAuthorizer? = nil,
        caskApplicationLifecycle: CaskApplicationLifecycle = .live
    ) {
        self.brewURL = brewURL
        self.runner = runner
        self.currentDirectoryURL = homeDirectoryURL
        self.developerDirectoryProbeURL = developerDirectoryProbeURL
        self.caskRemovalScanner = caskRemovalScanner ?? CaskRemovalScanner(home: homeDirectoryURL)
        self.caskRemovalAuthorizer = caskRemovalAuthorizer
        self.caskApplicationLifecycle = caskApplicationLifecycle

        let prefix = brewURL.deletingLastPathComponent().deletingLastPathComponent().path
        self.environment = [
            "HOME": homeDirectoryURL.path,
            "PATH": [
                brewURL.deletingLastPathComponent().path,
                "\(prefix)/sbin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                "/usr/sbin",
                "/sbin",
            ].joined(separator: ":"),
            "TMPDIR": temporaryDirectoryURL.path,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "USER": userName,
            "LOGNAME": userName,
            "HOMEBREW_NO_ANALYTICS": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
            "HOMEBREW_NO_AUTO_UPDATE": "1",
        ]
    }

    func loadSnapshot(includingOutdated: Bool = true) async throws -> HomebrewSnapshot {
        try validateExecutable()
        let versionOutput = try await checkedRun(["--version"])

        // Bounded concurrency: at most 2 Ruby brew invocations run at once (config + info, then outdated + tap-info).
        async let commandLineToolsTask = probeCommandLineTools()
        async let configurationTask: Result<HomebrewConfiguration, Error> = captureHomebrewRead {
            try await self.loadConfiguration()
        }
        async let packagesTask: Result<[HomebrewPackage], Error> = captureHomebrewRead {
            try await self.loadInstalledPackages()
        }

        let commandLineToolsAvailable = await commandLineToolsTask
        let configurationResult = await configurationTask
        let packagesResult = await packagesTask
        try Task.checkCancellation()

        async let outdatedTask: Result<[HomebrewOutdatedPackage], Error>? = includingOutdated
            ? captureHomebrewRead { try await self.loadOutdatedPackages() }
            : nil
        async let tapsTask: Result<[HomebrewTap], Error> = captureHomebrewRead {
            try await self.loadInstalledTaps()
        }

        let outdatedResult = await outdatedTask
        let tapsResult = await tapsTask

        try Task.checkCancellation()
        var sectionErrors: [HomebrewSnapshot.Section: String] = [:]

        let configuration: HomebrewConfiguration
        switch configurationResult {
        case .success(let value):
            configuration = value
        case .failure(let error):
            if error is CancellationError { throw error }
            configuration = HomebrewConfiguration(prefix: "", repository: "", cache: "", cellar: "", values: [:])
            sectionErrors[.configuration] = error.localizedDescription
        }

        let installedPackages: [HomebrewPackage]
        switch packagesResult {
        case .success(let value):
            installedPackages = value
        case .failure(let error):
            if error is CancellationError { throw error }
            installedPackages = []
            sectionErrors[.packages] = error.localizedDescription
        }

        var outdated: [HomebrewOutdatedPackage] = []
        if let outdatedResult {
            switch outdatedResult {
            case .success(let value):
                outdated = value
            case .failure(let error):
                if error is CancellationError { throw error }
                sectionErrors[.outdated] = error.localizedDescription
            }
        }

        let taps: [HomebrewTap]
        switch tapsResult {
        case .success(let value):
            taps = value
        case .failure(let error):
            if error is CancellationError { throw error }
            taps = []
            sectionErrors[.taps] = error.localizedDescription
        }

        try Task.checkCancellation()
        return HomebrewSnapshot(
            executablePath: brewURL.path,
            version: try requiredLine(versionOutput, label: "version"),
            configuration: configuration,
            packages: installedPackages,
            outdatedPackages: outdated,
            taps: taps,
            sectionErrors: sectionErrors,
            controlledPath: environment["PATH", default: ""],
            commandLineToolsAvailable: commandLineToolsAvailable
        )
    }

    private func loadInstalledPackages() async throws -> [HomebrewPackage] {
        let rawPackages = try await checkedRun(["info", "--json=v2", "--installed"])
        let envelope: BrewInfoEnvelope = try decode(rawPackages)
        var loaded = packages(from: envelope)
        if !AppRuntime.isRunningTests {
            for index in loaded.indices where loaded[index].identity.kind == .cask && loaded[index].isInstalled {
                loaded[index].detectedAppVersion = Self.detectInstalledCaskAppVersion(for: loaded[index])
            }
        }
        return loaded
    }

    private static func detectInstalledCaskAppVersion(for package: HomebrewPackage) -> String? {
        let appNames = package.artifacts
            .filter { $0.category == .installed && $0.kind == "app" }
            .flatMap { artifact -> [String] in
                if let application = artifact.application {
                    return [application.target ?? URL(filePath: application.source).lastPathComponent]
                }
                return artifact.values
            }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            URL(filePath: "/Applications"),
            home.appending(path: "Applications"),
            URL(filePath: "/Library/Input Methods"),
            home.appending(path: "Library/Input Methods"),
        ]
        for value in appNames {
            guard value.hasSuffix(".app"), !value.hasPrefix("/Volumes/"),
                  !value.contains(".."), !value.contains("*"), !value.contains("?") else { continue }
            let candidates: [URL]
            if value.hasPrefix("/") {
                candidates = [URL(filePath: value)]
            } else if value.hasPrefix("~/") {
                candidates = [home.appending(path: String(value.dropFirst(2)))]
            } else if !value.contains("/") {
                candidates = roots.map { $0.appending(path: value) }
            } else {
                continue
            }
            for appURL in candidates {
                let infoPlistURL = appURL.appending(path: "Contents/Info.plist")
                guard let data = try? Data(contentsOf: infoPlistURL),
                      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
                else { continue }
                if let shortVersion = (plist["CFBundleShortVersionString"] as? String)?.nilIfBlank {
                    return shortVersion
                }
                if let bundleVersion = (plist["CFBundleVersion"] as? String)?.nilIfBlank {
                    return bundleVersion
                }
            }
        }
        return nil
    }

    private func loadInstalledTaps() async throws -> [HomebrewTap] {
        let rawTaps = try await checkedRun(["tap-info", "--installed", "--json=v1"])
        let payload: [BrewTapPayload] = try decode(rawTaps)
        return payload.map(\.model).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func captureHomebrewRead<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async -> Result<Value, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }

    func loadOutdatedPackages() async throws -> [HomebrewOutdatedPackage] {
        try validateExecutable()
        let output = try await checkedRun(["outdated", "--json=v2"])
        let envelope: BrewOutdatedEnvelope = try decode(output)
        return envelope.models
    }

    func loadConfiguration() async throws -> HomebrewConfiguration {
        try validateExecutable()
        async let prefixOutput = checkedRun(["--prefix"])
        async let repositoryOutput = checkedRun(["--repository"])
        async let cacheOutput = checkedRun(["--cache"])
        async let cellarOutput = checkedRun(["--cellar"])
        let (prefix, repository, cache, cellar) = try await (prefixOutput, repositoryOutput, cacheOutput, cellarOutput)
        let config = try await checkedRun(["config"])
        return HomebrewConfiguration(
            prefix: try requiredLine(prefix, label: "prefix"),
            repository: try requiredLine(repository, label: "repository"),
            cache: try requiredLine(cache, label: "cache"),
            cellar: try requiredLine(cellar, label: "cellar"),
            values: parseConfiguration(config.standardOutput)
        )
    }

    func search(_ query: String) async throws -> [HomebrewSearchResult] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        try validateExecutable()

        let formulaResult = try await runSearch(term, kind: .formula)
        let caskResult = try await runSearch(term, kind: .cask)
        let results = formulaResult + caskResult
        return results.sorted {
            if $0.identity.kind != $1.identity.kind {
                return $0.identity.kind.sortOrder < $1.identity.kind.sortOrder
            }
            return $0.identity.name.localizedStandardCompare($1.identity.name) == .orderedAscending
        }
    }

    func search(_ query: String, kind: HomebrewPackageKind, limit: Int = 50) async throws -> [HomebrewSearchResult] {
        try Task.checkCancellation()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        guard term.utf8.count <= 512, (1...100).contains(limit) else {
            throw HomebrewClientError.invalidPlan("Invalid search query or result limit")
        }
        try validateExecutable()
        let results = try await runSearch(term, kind: kind)
        var seen = Set<HomebrewPackageIdentity>()
        return Array(results.filter { seen.insert($0.identity).inserted }
            .sorted { $0.identity.name.localizedStandardCompare($1.identity.name) == .orderedAscending }.prefix(limit))
    }

    func discover(_ query: String, kind: HomebrewPackageKind, limit: Int = 50,
                  maximumConcurrentDetails: Int = 4) async throws -> HomebrewDiscoveryResult {
        let matches = try await search(query, kind: kind, limit: limit)
        return try await Self.enrichDiscoveryMatches(matches, maximumConcurrentDetails: maximumConcurrentDetails) {
            try await self.loadPackage($0)
        }
    }

    static func enrichDiscoveryMatches(_ matches: [HomebrewSearchResult], maximumConcurrentDetails: Int,
        load: @escaping @Sendable (HomebrewPackageIdentity) async throws -> HomebrewPackage) async throws -> HomebrewDiscoveryResult {
        precondition((1...4).contains(maximumConcurrentDetails))
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: (Int, HomebrewPackage?).self) { group in
            func enqueue(_ index: Int) {
                _ = group.addTaskUnlessCancelled {
                    try Task.checkCancellation()
                    do {
                        let package = try await load(matches[index].identity)
                        try Task.checkCancellation()
                        return (index, package)
                    } catch {
                        if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
                            throw CancellationError()
                        }
                        return (index, nil)
                    }
                }
            }
            var next = 0
            while next < min(maximumConcurrentDetails, matches.count) {
                enqueue(next)
                next += 1
            }
            var packages: [Int: HomebrewPackage] = [:]
            var failed = 0
            for try await (index, package) in group {
                try Task.checkCancellation()
                if let package { packages[index] = package } else { failed += 1 }
                if next < matches.count {
                    enqueue(next)
                    next += 1
                }
            }
            try Task.checkCancellation()
            var seen = Set<HomebrewPackageIdentity>()
            let ordered = matches.indices.compactMap { packages[$0] }.filter { seen.insert($0.identity).inserted }
            return HomebrewDiscoveryResult(packages: ordered, failedDetailCount: failed)
        }
    }

    func loadPackage(_ identity: HomebrewPackageIdentity) async throws -> HomebrewPackage {
        try validateExecutable()
        let validatedIdentity = HomebrewPackageIdentity(
            name: try validatedPackageName(identity.name),
            kind: identity.kind
        )
        let result = try await checkedRun(infoArguments(for: validatedIdentity))
        let envelope: BrewInfoEnvelope = try decode(result)
        let returned = packages(from: envelope).filter { $0.identity.kind == validatedIdentity.kind }
        guard returned.count == 1, let package = returned.first else {
            throw HomebrewClientError.invalidJSON(arguments: result.arguments, detail: "Package information was not returned")
        }
        let components = validatedIdentity.name.split(separator: "/").map(String.init)
        guard let requestedName = components.last else { throw HomebrewClientError.stateChanged }
        let canonicalName = package.identity.name.split(separator: "/").last.map(String.init)
        let sourceMatches = components.count == 1 || components.dropLast().joined(separator: "/") == package.tap
        let nameMatches = requestedName == canonicalName || package.aliases.contains(requestedName) || package.oldTokens.contains(requestedName)
        if !sourceMatches || !nameMatches {
            throw HomebrewClientError.invalidJSON(arguments: result.arguments, detail: "Returned package identity does not match the request")
        }
        return package
    }

    func diagnose() async throws -> HomebrewDiagnosticReport {
        try validateExecutable()
        let result = try await run(["doctor"])
        let allLines = outputLines(result.standardOutput) + outputLines(result.standardError)
        let lines = Array(allLines.prefix(1_000))
        let diagnostics: [HomebrewDiagnostic]
        if result.standardOutputWasTruncated || result.standardErrorWasTruncated {
            diagnostics = [HomebrewDiagnostic(
                id: "doctor-output-truncated",
                severity: .error,
                message: "brew doctor output exceeded the safety limit; diagnostics are incomplete."
            )]
        } else if lines.isEmpty, result.terminationStatus == 0 {
            diagnostics = [HomebrewDiagnostic(id: "healthy", severity: .info, message: "Your system is ready to brew.")]
        } else if lines.isEmpty {
            diagnostics = [HomebrewDiagnostic(
                id: "doctor-empty-error",
                severity: .error,
                message: "brew doctor exited with a non-zero status without returning diagnostic output."
            )]
        } else {
            let defaultSeverity: HomebrewDiagnosticSeverity = result.terminationStatus == 0 ? .info : .warning
            var parsed = lines.enumerated().map { index, line in
                HomebrewDiagnostic(
                    id: "\(index):\(line)",
                    severity: diagnosticSeverity(for: line, default: defaultSeverity),
                    message: line
                )
            }
            if allLines.count > lines.count {
                parsed.append(HomebrewDiagnostic(
                    id: "doctor-line-limit",
                    severity: .warning,
                    message: "brew doctor returned too many lines; showing only the first \(lines.count)."
                ))
            }
            diagnostics = parsed
        }
        return HomebrewDiagnosticReport(diagnostics: diagnostics, command: result)
    }


    private func infoArguments(for identity: HomebrewPackageIdentity) -> [String] {
        ["info", "--json=v2", identity.kind == .formula ? "--formula" : "--cask", identity.name]
    }

    private func runSearch(_ query: String, kind: HomebrewPackageKind) async throws -> [HomebrewSearchResult] {
        let result = try await run(["search", kind == .formula ? "--formula" : "--cask", "--", query])
        guard !result.standardOutputWasTruncated, !result.standardErrorWasTruncated else {
            throw HomebrewClientError.outputTruncated(arguments: result.arguments)
        }
        if result.terminationStatus != 0 {
            let message = result.standardError + "\n" + result.standardOutput
            guard message.localizedCaseInsensitiveContains("No formulae or casks found") else {
                throw HomebrewClientError.commandFailed(result)
            }
            return []
        }
        return outputLines(result.standardOutput)
            .filter { !$0.hasPrefix("==>") }
            .map { HomebrewSearchResult(identity: HomebrewPackageIdentity(name: $0, kind: kind)) }
    }

    func checkedRun(_ arguments: [String]) async throws -> HomebrewCommandOutput {
        let result = try await run(arguments)
        guard !result.standardOutputWasTruncated, !result.standardErrorWasTruncated else {
            throw HomebrewClientError.outputTruncated(arguments: result.arguments)
        }
        guard result.terminationStatus == 0 else {
            throw HomebrewClientError.commandFailed(result)
        }
        return result
    }

    func run(
        _ arguments: [String],
        environment overrideEnvironment: [String: String]? = nil,
        timeout: Duration? = .seconds(300)
    ) async throws -> HomebrewCommandOutput {
        let result = try await runner.run(ProcessRequest(
            executableURL: brewURL,
            arguments: arguments,
            environment: overrideEnvironment ?? environment,
            currentDirectoryURL: currentDirectoryURL,
            timeout: timeout
        ))
        return HomebrewCommandOutput(
            arguments: arguments,
            standardOutput: result.outputText,
            standardError: result.errorText,
            terminationStatus: result.terminationStatus,
            standardOutputWasTruncated: result.standardOutputWasTruncated,
            standardErrorWasTruncated: result.standardErrorWasTruncated
        )
    }

    func validateExecutable() throws {
        guard brewURL.isFileURL, brewURL.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: brewURL.path) else {
            throw HomebrewClientError.executableNotFound(brewURL.path)
        }
    }

    private func probeCommandLineTools() async -> Bool {
        guard developerDirectoryProbeURL.isFileURL,
              FileManager.default.isExecutableFile(atPath: developerDirectoryProbeURL.path)
        else { return false }
        guard let result = try? await runner.run(ProcessRequest(
            executableURL: developerDirectoryProbeURL,
            arguments: ["-p"],
            environment: environment,
            currentDirectoryURL: currentDirectoryURL,
            timeout: .seconds(10),
            standardOutputLimit: 16 * 1_024,
            standardErrorLimit: 16 * 1_024
        )) else { return false }
        return result.terminationStatus == 0
            && !result.outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func decode<Payload: Decodable>(_ result: HomebrewCommandOutput) throws -> Payload {
        do {
            return try JSONDecoder().decode(Payload.self, from: Data(result.standardOutput.utf8))
        } catch {
            throw HomebrewClientError.invalidJSON(arguments: result.arguments, detail: error.localizedDescription)
        }
    }

    func requiredLine(_ output: HomebrewCommandOutput, label: String) throws -> String {
        guard let line = outputLines(output.standardOutput).first else {
            throw HomebrewClientError.invalidJSON(arguments: output.arguments, detail: "Missing \(label)")
        }
        return line
    }

    func outputLines(_ value: String) -> [String] {
        value.split(whereSeparator: \.isNewline).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private func parseConfiguration(_ value: String) -> [String: String] {
        outputLines(value).reduce(into: [:]) { result, line in
            guard let separator = line.firstIndex(of: ":") else { return }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let item = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return }
            result[key] = item
        }
    }

    private func packages(from envelope: BrewInfoEnvelope) -> [HomebrewPackage] {
        (envelope.formulae.map(\.model) + envelope.casks.map(\.model)).sorted {
            if $0.identity.kind != $1.identity.kind {
                return $0.identity.kind.sortOrder < $1.identity.kind.sortOrder
            }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private func diagnosticSeverity(
        for line: String,
        default defaultSeverity: HomebrewDiagnosticSeverity
    ) -> HomebrewDiagnosticSeverity {
        if line.localizedCaseInsensitiveContains("error") {
            return .error
        }
        if line.localizedCaseInsensitiveContains("warning")
            || line.localizedCaseInsensitiveContains("problem")
        {
            return .warning
        }
        return defaultSeverity
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
