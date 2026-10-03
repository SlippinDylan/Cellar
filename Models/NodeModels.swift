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
}

struct NodeActionPlan: Identifiable, Sendable {
    let id: UUID
    let request: NodeActionRequest
    let payload: NodeActionPlanPayload
    let generatedAt: Date

    var canExecute: Bool {
        payload.executeSupported != false && payload.executable != false && payload.alreadyInstalled != true
    }
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
}

struct NodeActionResult: Sendable {
    let plan: NodeActionPlan
    let operation: NodeOperationResult
    let snapshot: NodeSnapshot?
    let postflightError: String?
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
}
