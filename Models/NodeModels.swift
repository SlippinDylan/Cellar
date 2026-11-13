import Foundation

struct ManagerErrorPayload: Decodable, Error, Sendable {
    let code: String
    let message: String?
    let dependencies: [String]?
    let stderr: String?
    let operationId: String?
    let action: String?
    let subject: String?
    let exitCode: Int?
    let status: String?
    let logFile: String?
    let causeCode: String?

    private enum CodingKeys: String, CodingKey {
        case code, message, dependencies, stderr, operationId, action, subject, exitCode, status, logFile, causeCode, detail
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        action = try values.decodeIfPresent(String.self, forKey: .action)
        exitCode = try values.decodeIfPresent(Int.self, forKey: .exitCode)
        status = try values.decodeIfPresent(String.self, forKey: .status)
        if let explicitCode = try values.decodeIfPresent(String.self, forKey: .code) { code = explicitCode }
        else {
            // The frozen uninstall adapter returns this operation-shaped error without a code.
            guard action == NodeAction.uninstallPackage.rawValue, exitCode == 0, status == "failed",
                  try values.decodeIfPresent(String.self, forKey: .detail) == "post-uninstall-state-unavailable" else {
                throw DecodingError.keyNotFound(CodingKeys.code, .init(codingPath: values.codingPath, debugDescription: "Provider errors require a code"))
            }
            code = "post-uninstall-state-unavailable"
        }
        message = try values.decodeIfPresent(String.self, forKey: .message)
        dependencies = try values.decodeIfPresent([String].self, forKey: .dependencies)
        stderr = try values.decodeIfPresent(String.self, forKey: .stderr)
        operationId = try values.decodeIfPresent(String.self, forKey: .operationId)
        subject = try values.decodeIfPresent(String.self, forKey: .subject)
        logFile = try values.decodeIfPresent(String.self, forKey: .logFile)
        causeCode = try values.decodeIfPresent(String.self, forKey: .causeCode)
    }
}

struct ManagerEnvelope<Payload: Decodable & Sendable>: Decodable, Sendable {
    let ok: Bool
    let schemaVersion: Int
    let command: String
    let data: Payload?
    let error: ManagerErrorPayload?
}

struct NodeSummary: Decodable, Sendable {
    let nodePath: String
    let npmPath: String
    let nodeVersion: String
    let npmVersion: String
    let nvmLoaded: Bool
    let globalPrefix: String
    let globalRoot: String
    let registry: String
}

struct NodePackageInventory: Decodable, Sendable {
    struct Package: Decodable, Sendable {
        let version: String?
    }

    let dependencies: [String: Package]?
}

struct OutdatedPackage: Decodable, Sendable {
    let current: String
    let wanted: String
    let latest: String
}

struct NodeConfiguration: Decodable, Sendable {
    let registry: String
    let cache: String
    let prefix: String
    let userRegistry: String
    let projectRegistry: String
    let globalRegistry: String
}

struct NodePackageRow: Identifiable, Sendable {
    let name: String
    let installedVersion: String
    let wantedVersion: String?
    let latestVersion: String?

    var id: String { name }
    var isOutdated: Bool { latestVersion != nil && latestVersion != installedVersion }
}

struct NodeInstallation: Identifiable, Sendable, Hashable {
    let version: String
    let directory: String
    let isActive: Bool
    let isDefault: Bool

    var id: String { version }
}

struct NodeManagerStatus: Decodable, Sendable {
    let ok: Bool
    let runtimeDir: String
    let logDir: String
    let tmpDir: String
    let jsonExecuteEnabled: Bool
}

enum NodeAction: String, Codable, Sendable {
    case installPackage = "install"
    case uninstallPackage = "uninstall"
    case updatePackage = "update-latest"
    case setRegistry = "registry-set"
    case deleteRegistry = "registry-delete"
    case setScopeRegistry = "scope-registry-set"
    case deleteScopeRegistry = "scope-registry-delete"
    case installNVM = "nvm-install"
    case installNode = "node-install"
    case useNode = "node-use"
    case setDefaultNode = "node-default"
    case uninstallNode = "node-uninstall"
    case cleanup
    case writeProjectNVMRC = "project-nvmrc"

    var isRegistryConfiguration: Bool {
        [.setRegistry, .deleteRegistry, .setScopeRegistry, .deleteScopeRegistry].contains(self)
    }
}

struct NodeActionRequest: Sendable, Equatable {
    let action: NodeAction
    let subject: String
    let value: String?

    init(action: NodeAction, subject: String = "", value: String? = nil) {
        self.action = action
        self.subject = subject
        self.value = value
    }
}

struct NodeActionPlanPayload: Decodable, Sendable {
    let action: String
    let subject: String?
    let value: String?
    let targetType: String?
    let packageSpec: String?
    let packageName: String?
    let installedVersion: String?
    let targetVersion: String?
    let alreadyInstalled: Bool?
    let requiresConfirmation: Bool?
    let executeSupported: Bool?
    let externalWrite: Bool?
    let executable: Bool?
    let blockedReason: String?
    let logFileHint: String?
    let paths: [String]?
    let planToken: String?
    let nvmAvailable: Bool?
    let normalizedVersion: String?
    let currentVersion: String?
    let defaultVersion: String?
    let defaultStatus: String?
    let versionDir: String?
    let versionDirExists: Bool?
    let versionDirSize: String?
    let globalPackageSummary: String?
    let protectedByCurrent: Bool?
    let protectedByDefault: Bool?
    let processOnly: Bool?
    let persistent: Bool?
    let requestedVersion: String?
    let resolvedVersion: String?
    let installUrl: String?
    let sha256: String?
    let sha256Configured: Bool?
    let allowUnverified: Bool?
    let targetDir: String?
    let pathExists: Bool?
    let pathIsDirectory: Bool?
    let nvmrcPath: String?
    let currentNvmrc: String?
    let packageJsonExists: Bool?
    let enginesNode: String?
    let nvmrcIsSymlink: Bool?
    let effectiveRegistry: String?
    let userRegistry: String?
    let projectRegistry: String?
    let globalRegistry: String?
}

struct NodeActionPlan: Identifiable, Sendable {
    let id: UUID
    let request: NodeActionRequest
    let payload: NodeActionPlanPayload
    let generatedAt: Date
    // Session-only confirmation state, never part of the Manager JSON or Activity storage.
    let confirmedPackageDestination: NodePackageDestination?
    let confirmedInstallRegistry: URL?
    let maintenanceCandidates: [String]

    init(id: UUID, request: NodeActionRequest, payload: NodeActionPlanPayload, generatedAt: Date,
         confirmedPackageDestination: NodePackageDestination? = nil, confirmedInstallRegistry: URL? = nil, maintenanceCandidates: [String] = []) {
        self.id = id
        self.request = request
        self.payload = payload
        self.generatedAt = generatedAt
        self.confirmedPackageDestination = confirmedPackageDestination
        self.confirmedInstallRegistry = confirmedInstallRegistry
        self.maintenanceCandidates = maintenanceCandidates
    }

    var canExecute: Bool {
        payload.executeSupported != false && payload.executable != false && payload.alreadyInstalled != true
            && (request.action != .updatePackage || exactUpdateSpec != nil)
    }

    var exactUpdateSpec: String? {
        guard request.action == .updatePackage, let packageName = payload.packageName,
              packageName == request.subject, let target = payload.targetVersion,
              SemanticVersionStatus(current: payload.installedVersion, available: target) == .behind else { return nil }
        return "\(packageName)@\(target)"
    }

    var exactInstallSpec: String? {
        guard request.action == .installPackage, DiscoverBatchInput.validNPMSpec(request.subject),
              let packageName = payload.packageName, let target = payload.targetVersion,
              SemanticVersionStatus(current: target, available: target) == .current else { return nil }
        let scoped = request.subject.hasPrefix("@")
        let name = request.subject.dropFirst(scoped ? 1 : 0).split(separator: "@", maxSplits: 1)[0]
        guard packageName == (scoped ? "@" : "") + name else { return nil }
        return "\(packageName)@\(target)"
    }
}

struct NodePackageDestination: Equatable, Sendable {
    let nodeExecutable: String
    let npmExecutable: String
    let globalPrefix: String
    let globalRoot: String
}

struct NodeOperationResult: Decodable, Sendable {
    struct Residues: Decodable, Sendable {
        let directories: [String]
        let bins: [String]
    }

    let operationId: String
    let action: String
    let subject: String
    let exitCode: Int
    let status: String
    let logFile: String
    let detail: String?
    let residues: Residues?

    var batchItemStatus: BatchItemStatus {
        if let detail, let verification = ActivityItemReason.verificationStatus(code: detail) {
            return verification == .partiallySucceeded && exitCode != 0 ? .failed : verification
        }
        guard exitCode == 0 else { return .failed }
        if [NodeAction.installPackage.rawValue, NodeAction.updatePackage.rawValue, NodeAction.writeProjectNVMRC.rawValue].contains(action), status == "unknown" { return .unknown }
        if status == "ok" { return .succeeded }
        if action == NodeAction.uninstallPackage.rawValue, status == "warn", detail == "residue-detected" {
            return .partiallySucceeded
        }
        return .failed
    }

    var activityReason: ActivityItemReason? {
        switch batchItemStatus {
        case .skipped: .alreadySatisfied
        case .succeeded: nil
        case .cancelled: .cancelledByUser
        case .unknown: detail == "project-changed" ? .stateChanged : .stateUnavailable
        case .partiallySucceeded: detail == "residue-detected" ? .residueDetected : .stateUnavailable
        case .failed: .init(error: BridgeError.managerFailure(code: detail ?? "provider-failure", detail: nil))
        }
    }
}

struct NodeActionResult: Sendable {
    let plan: NodeActionPlan
    let operation: NodeOperationResult
    let snapshot: NodeSnapshot?
    let postflightError: String?
}

struct NodeCacheVerification: Sendable {
    struct Target: Equatable, Sendable {
        let environment: NodeEnvironmentContext
        let npmPath: String
        let cachePath: String

        init(node: NodeSnapshot) {
            environment = LibraryCatalog.context(node.summary)
            npmPath = node.summary.npmPath
            cachePath = node.configuration.cache
        }
    }

    enum State: Sendable {
        case running
        case completed(NodeActionResult)
        case failed
    }

    let target: Target
    let state: State
}

struct NodeSnapshot: Sendable {
    let summary: NodeSummary
    let configuration: NodeConfiguration
    let packages: [NodePackageRow]
    let installations: [NodeInstallation]
    let managerStatus: NodeManagerStatus?
    let logs: [String]
    let outdatedError: String?
    let maintenanceError: String?

    func replacingOutdated(packages outdated: [String: OutdatedPackage], error: String?) -> Self {
        let rows = packages.map { package in
            NodePackageRow(name: package.name, installedVersion: package.installedVersion,
                           wantedVersion: outdated[package.name]?.wanted, latestVersion: outdated[package.name]?.latest)
        }
        return Self(summary: summary, configuration: configuration, packages: rows, installations: installations,
                    managerStatus: managerStatus, logs: logs, outdatedError: error, maintenanceError: maintenanceError)
    }

    func retainingKnownOutdated(from previous: Self?) -> Self {
        // npm can update itself without changing package ownership in this installation and global directory.
        guard outdatedError != nil, let previous,
              summary.nodePath == previous.summary.nodePath, summary.nodeVersion == previous.summary.nodeVersion,
              summary.npmPath == previous.summary.npmPath, summary.globalPrefix == previous.summary.globalPrefix,
              summary.globalRoot == previous.summary.globalRoot else { return self }
        let known = Dictionary(uniqueKeysWithValues: previous.packages.map { ($0.name, $0) })
        let rows = packages.map { package in
            NodePackageRow(name: package.name, installedVersion: package.installedVersion,
                           wantedVersion: package.wantedVersion ?? known[package.name]?.wantedVersion,
                           latestVersion: package.latestVersion ?? known[package.name]?.latestVersion)
        }
        return Self(summary: summary, configuration: configuration, packages: rows, installations: installations,
                    managerStatus: managerStatus, logs: logs, outdatedError: outdatedError, maintenanceError: maintenanceError)
    }
}
