import Foundation

struct ManagerErrorPayload: Decodable, Error, Sendable {
    let code: String
    let message: String?
    let dependencies: [String]?
    let stderr: String?
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

struct NodeSnapshot: Sendable {
    let summary: NodeSummary
    let configuration: NodeConfiguration
    let packages: [NodePackageRow]
    let outdatedError: String?
}
