import Combine
import Foundation

enum ActivityStoreError: Error, Equatable {
    case corruptData
    case unsupportedSchema(Int)
    case isolationFailed
    case readFailed
    case invalidSummary
    case writeFailed
}

@MainActor
final class ActivityStore: ObservableObject {
    static let maximumFileBytes = 1_048_576
    @Published private(set) var summaries: [ActivitySummary] = []
    @Published private(set) var persistenceError: ActivityStoreError?
    let fileURL: URL
    private var blockedError: ActivityStoreError?
    private var didRestore = false
    private var pendingSummaries: [ActivitySummary] = []

    init(applicationSupportRoot: URL) {
        fileURL = applicationSupportRoot.appending(path: "Cellar/Activity/activity.json")
    }

    func restore() {
        guard !didRestore else { return }
        didRestore = true
        retryLoading()
    }

    func retryLoading() {
        do {
            try load()
            persistenceError = nil
        } catch {
            persistenceError = error
        }
    }

    func append(_ summary: ActivitySummary) {
        do {
            try record(summary)
            persistenceError = nil
        } catch {
            persistenceError = error
        }
    }

    func retrySaving() {
        guard let pending = pendingSummaries.first else { return }
        append(pending)
    }

    func load() throws(ActivityStoreError) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            blockedError = nil
            summaries = pendingSummaries
            return
        }
        let data: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.intValue <= Self.maximumFileBytes
            else { try isolate(.corruptData) }
            data = try Data(contentsOf: fileURL)
        } catch let error as ActivityStoreError {
            throw error
        } catch {
            blockedError = .readFailed
            throw .readFailed
        }
        let envelope: PersistedActivityEnvelope
        do {
            let header = try JSONDecoder().decode(SchemaHeader.self, from: data)
            guard [1, PersistedActivityEnvelope.currentSchemaVersion].contains(header.schemaVersion) else {
                try isolate(.unsupportedSchema(header.schemaVersion))
            }
            envelope = try JSONDecoder().decode(PersistedActivityEnvelope.self, from: data)
        } catch let error as ActivityStoreError {
            throw error
        } catch {
            try isolate(.corruptData)
        }
        do {
            let sanitized = try envelope.summaries.map(ActivitySummarySanitizer.sanitize)
            summaries = Self.boundedUnique(pendingSummaries + sanitized)
            blockedError = nil
        } catch {
            try isolate(.corruptData)
        }
    }

    func record(_ summary: ActivitySummary) throws(ActivityStoreError) {
        if let blockedError { throw blockedError }
        let sanitized = try ActivitySummarySanitizer.sanitize(summary)
        let updated = Self.boundedUnique([sanitized] + pendingSummaries + summaries)
        do {
            let data = try JSONEncoder().encode(PersistedActivityEnvelope(summaries: updated))
            guard data.count <= Self.maximumFileBytes else { throw ActivityStoreError.invalidSummary }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch let error as ActivityStoreError {
            throw error
        } catch {
            pendingSummaries = Self.boundedUnique([sanitized] + pendingSummaries)
            summaries = updated
            throw .writeFailed
        }
        pendingSummaries = []
        summaries = updated
    }

    private func isolate(_ error: ActivityStoreError) throws(ActivityStoreError) -> Never {
        summaries = pendingSummaries
        let isolatedURL = fileURL.deletingLastPathComponent().appending(path: "activity-\(UUID().uuidString).isolated")
        do {
            try FileManager.default.moveItem(at: fileURL, to: isolatedURL)
        } catch {
            blockedError = .isolationFailed
            throw .isolationFailed
        }
        blockedError = nil
        throw error
    }

    private struct SchemaHeader: Decodable {
        let schemaVersion: Int
    }

    private static func boundedUnique(_ records: [ActivitySummary]) -> [ActivitySummary] {
        var identifiers: Set<UUID> = []
        return Array(records.filter { identifiers.insert($0.id).inserted }.prefix(100))
    }
}

enum ActivitySummarySanitizer {
    static func sanitize(_ summary: ActivitySummary) throws(ActivityStoreError) -> ActivitySummary {
        guard summary.status != .running, summary.targetDisplayNames.count <= 100, summary.itemOutcomes.count <= 100 else { throw .invalidSummary }
        if summary.scope == .shell {
            guard summary.date.timeIntervalSince1970.isFinite, summary.targetDisplayNames.isEmpty,
                  summary.itemOutcomes.allSatisfy({ $0.displayName.isEmpty && $0.shellStep != nil }),
                  Set(summary.itemOutcomes.compactMap(\.shellStep)).count == summary.itemOutcomes.count else { throw .invalidSummary }
            return summary
        }
        guard summary.date.timeIntervalSince1970.isFinite,
              summary.targetDisplayNames.allSatisfy({ validPackageIdentifier($0, scope: summary.scope) }),
              summary.itemOutcomes.allSatisfy({ $0.shellStep == nil && validPackageIdentifier($0.displayName, scope: summary.scope) })
        else { throw .invalidSummary }
        let scope: ActivityScope?
        switch summary.scope {
        case .npm(let environment), .nodeRuntime(let environment):
            guard validVersion(environment.nodeVersion), validVersion(environment.npmVersion) else { throw .invalidSummary }
            // Persist versions as semantic context; identifiers may contain private installation paths.
            let sanitizedEnvironment = NodeEnvironmentContext(
                identifier: "nvm:\(environment.nodeVersion)",
                nodeVersion: environment.nodeVersion,
                npmVersion: environment.npmVersion
            )
            if case .nodeRuntime = summary.scope { scope = .nodeRuntime(sanitizedEnvironment) }
            else { scope = .npm(sanitizedEnvironment) }
        case .homebrew, .homebrewTaps, .homebrewMetadata, .homebrewDiagnostics, .shell, nil:
            scope = summary.scope
        }
        return ActivitySummary(id: summary.id, operation: summary.operation, scope: scope,
                               targetDisplayNames: summary.targetDisplayNames, date: summary.date,
                               status: summary.status, itemOutcomes: summary.itemOutcomes, reason: summary.reason)
    }

    private static func validVersion(_ version: String) -> Bool {
        let normalized = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let pieces = normalized.split(separator: ".", omittingEmptySubsequences: false)
        return normalized.count <= 64 && pieces.count == 3
            && pieces.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }
    }

    private static func validPackageIdentifier(_ name: String, scope: ActivityScope?) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 214 else { return false }
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        switch scope {
        case .homebrewTaps:
            return validHomebrewTap(name)
        case .homebrewMetadata, .homebrewDiagnostics:
            return false
        case .nodeRuntime:
            return validVersion(name)
        case .npm:
            return DiscoverBatchInput.validNPMSpec(name)
        case .homebrew:
            guard !name.hasPrefix("@"), components.count == 1 || components.count == 3 else { return false }
        case .shell, nil:
            return false
        }
        for (index, component) in components.enumerated() {
            let value = index == 0 && component.hasPrefix("@") ? component.dropFirst() : component[...]
            let versionParts = value.split(separator: "@", omittingEmptySubsequences: false)
            guard versionParts.count <= 2, let namePart = versionParts.first,
                  !namePart.isEmpty, namePart != ".", namePart != "..",
                  namePart.utf8.first.map({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) == true,
                  namePart.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95, 43].contains($0) })
            else { return false }
            if versionParts.count == 2 {
                let version = versionParts[1].split(separator: ".", omittingEmptySubsequences: false)
                guard (1...3).contains(version.count),
                      version.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } })
                else { return false }
            }
        }
        return true
    }

    static func validHomebrewTap(_ name: String) -> Bool {
        guard name.utf8.count <= 214, !name.hasPrefix("-") else { return false }
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        return components.count == 2 && components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
                && component.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [43, 45, 46, 95].contains($0) }
        }
    }
}
