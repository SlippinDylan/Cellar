import Foundation

actor NodeManagerClient {
    private let runner: ProcessRunner
    private let environmentResolver: NodeEnvironmentResolver

    init(runner: ProcessRunner, environmentResolver: NodeEnvironmentResolver = NodeEnvironmentResolver()) {
        self.runner = runner
        self.environmentResolver = environmentResolver
    }

    func loadSnapshot(managerDirectory: URL) async throws -> NodeSnapshot {
        let environment = environmentResolver.environment()
        let summaryValue: NodeSummary = try await request(
            "summary", managerDirectory: managerDirectory, environment: environment
        )
        let inventoryValue: NodePackageInventory = try await request(
            "packages", managerDirectory: managerDirectory, environment: environment
        )
        let configurationValue: NodeConfiguration = try await request(
            "config", managerDirectory: managerDirectory, environment: environment
        )
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
            outdatedError: outdatedError
        )
    }

    func request<Payload: Decodable & Sendable>(
        _ command: String,
        managerDirectory: URL,
        environment: [String: String]
    ) async throws -> Payload {
        let mainScript = managerDirectory.appending(path: "main.sh")
        guard FileManager.default.isReadableFile(atPath: mainScript.path) else {
            throw BridgeError.executableNotFound(mainScript.path)
        }

        let result = try await runner.run(ProcessRequest(
            executableURL: URL(filePath: "/bin/bash"),
            arguments: [mainScript.path, "--json", command],
            environment: environment,
            currentDirectoryURL: managerDirectory
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
