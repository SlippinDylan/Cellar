import Foundation

struct CaskApplicationIdentity: Codable, Hashable, Sendable {
    let bundleURL: URL
    let bundleIdentifier: String
}

enum CaskRemovalPathStatus: Sendable, Equatable {
    case pending, removing, removed, retained, unverified
}

struct CaskRemovalPathResult: Sendable, Equatable {
    enum Outcome: Sendable { case removed, retained, unverified }
    let path: String
    let outcome: Outcome

    var progress: CaskRemovalProgress {
        let status: CaskRemovalPathStatus = switch outcome {
        case .removed: .removed
        case .retained: .retained
        case .unverified: .unverified
        }
        return .init(path: path, status: status)
    }
}

struct CaskRemovalProgress: Sendable, Equatable {
    let path: String
    let status: CaskRemovalPathStatus
}

typealias CaskRemovalProgressHandler = @Sendable (CaskRemovalProgress) async -> Void

enum CaskRemovalCategory: String, CaseIterable, Codable, Sendable, Hashable {
    case application, cache, applicationData, homebrewCache
}

enum CaskRemovalDisposition: String, Codable, Sendable, Hashable {
    case homebrew, remove, protected
}

enum CaskRemovalWarning: String, Codable, Sendable, Hashable {
    case sharedData, incompleteScan, uninstallerRequiresAuthorization
}

enum CaskRemovalSizeFailure: String, Codable, Sendable, Hashable {
    case permissionDenied, limitReached, unsafePath, fileChanged, notFound, ioFailure
}

struct CaskRemovalEntry: Identifiable, Codable, Sendable, Hashable {
    let path: String
    let category: CaskRemovalCategory
    let estimatedBytes: Int64?
    let disposition: CaskRemovalDisposition
    let fingerprint: String
    var sizeFailure: CaskRemovalSizeFailure? = nil

    var id: String { path }
}

struct CaskRemovalPlan: Codable, Sendable {
    let displayName: String
    let appURL: URL?
    let entries: [CaskRemovalEntry]
    let warnings: [CaskRemovalWarning]
    let ownershipFingerprint: String
    var applicationIdentities: [CaskApplicationIdentity] = []
    var installedMetadataFingerprint: String? = nil

    var applicationBytes: Int64? { total(entries.filter { $0.category == .application }) }
    var removalBytes: Int64? { total(entries.filter { $0.disposition != .protected }) }

    private func total(_ entries: [CaskRemovalEntry]) -> Int64? {
        guard !entries.isEmpty else { return nil }
        var total: Int64 = 0
        var measuredIdentities = Set<String>()
        for entry in entries {
            guard measuredIdentities.insert(entry.fingerprint).inserted else { continue }
            guard let bytes = entry.estimatedBytes else { return nil }
            total += bytes
        }
        return total
    }
}

struct CaskRemovalFailure: Codable, Sendable {
    let path: String
    let reason: String
    var recoveryReason: ActivityItemReason = .providerFailure
}

extension CaskRemovalFailure {
    init(path: String, error: Error) {
        self.init(path: path, reason: error.localizedDescription, recoveryReason: .init(error: error))
    }
}
