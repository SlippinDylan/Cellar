import Foundation

// Progress is historical; completion describes only what can be observed at the confirmed paths now.
struct CaskRemovalPostflight: Sendable {
    let paths: [CaskRemovalPathResult]
    let remaining: [HomebrewResidualPath]
    let failures: [CaskRemovalFailure]

    static func observe(removal: CaskRemovalPlan, failures: [CaskRemovalFailure], installationRemoved: Bool) async -> Self {
        // Required read-only reconciliation must finish even when its owner has cancelled deletion.
        await Task.detached(priority: .utility) {
            Self(removal: removal, failures: failures, installationRemoved: installationRemoved)
        }.value
    }

    init(removal: CaskRemovalPlan, failures: [CaskRemovalFailure], installationRemoved: Bool) {
        var paths: [CaskRemovalPathResult] = []
        var remaining: [HomebrewResidualPath] = []
        var observationFailures: [CaskRemovalFailure] = []
        let budget = CaskRemovalScanBudget(entries: removal.entries.count, duration: .seconds(2))
        for entry in removal.entries {
            do {
                try budget.check()
                let present = try CaskRemovalFileSystem.isPresent(entry.path)
                let outcome: CaskRemovalPathResult.Outcome = entry.disposition == .protected || present
                    ? .retained : installationRemoved ? .removed : .unverified
                paths.append(.init(path: entry.path, outcome: outcome))
                if present { remaining.append(.init(path: entry.path, artifactKind: entry.category.rawValue, estimatedBytes: nil)) }
            } catch {
                paths.append(.init(path: entry.path, outcome: entry.disposition == .protected ? .retained : .unverified))
                remaining.append(.init(path: entry.path, artifactKind: entry.category.rawValue, estimatedBytes: nil))
                if entry.disposition != .protected && !failures.contains(where: { $0.path == entry.path }) {
                    observationFailures.append(.init(path: entry.path, error: error))
                }
            }
        }
        let unresolved = Set(remaining.map(\.path))
        self.paths = paths
        self.remaining = remaining
        self.failures = failures.filter { unresolved.contains($0.path) } + observationFailures
    }
}
