import Foundation

extension HomebrewClient {
    func execute(_ plan: HomebrewActionPlan, caskRemovalProgress: CaskRemovalProgressHandler? = nil) async throws -> HomebrewActionResult {
        try await withMutationLock {
            let progress: CaskRemovalProgressReporter?
            if let removal = plan.caskRemoval, let caskRemovalProgress {
                progress = CaskRemovalProgressReporter(entries: removal.entries, handler: caskRemovalProgress)
            } else { progress = nil }
            await progress?.start()
            var installationRemoved = false
            do {
                var result = try await executeConfirmed(plan, progress: progress, installationRemoved: &installationRemoved)
                if let removal = plan.caskRemoval {
                    let observed = await CaskRemovalPostflight.observe(removal: removal, failures: result.caskRemovalFailures,
                        installationRemoved: installationRemoved)
                    result = HomebrewActionResult(plan: result.plan, command: result.command, snapshot: result.snapshot,
                        postflightError: result.postflightError, remainingResidualPaths: observed.remaining,
                        caskRemovalFailures: observed.failures, caskRemovalPathResults: observed.paths)
                }
                await progress?.finish(paths: result.caskRemovalPathResults)
                return result
            } catch {
                let paths: [CaskRemovalPathResult]
                if let removal = plan.caskRemoval {
                    paths = await CaskRemovalPostflight.observe(removal: removal, failures: [],
                        installationRemoved: installationRemoved).paths
                } else { paths = [] }
                await progress?.finish(paths: paths)
                throw error
            }
        }
    }

    private func executeConfirmed(_ plan: HomebrewActionPlan, progress: CaskRemovalProgressReporter?,
                                  installationRemoved: inout Bool) async throws -> HomebrewActionResult {
        guard plan.canExecute else {
            throw HomebrewClientError.invalidPlan("Tap still has associated installed packages and cannot be removed")
        }
        guard Date().timeIntervalSince(plan.generatedAt) <= 300 else {
            throw HomebrewClientError.stateChanged
        }
        try validateExecutable()
        if let removal = plan.caskRemoval {
            guard plan.action == .uninstallCask, plan.targets.count == 1,
                  let target = plan.targets.first, target.kind == .cask else { throw HomebrewClientError.stateChanged }
            let current = try await planCaskRemoval(target.name)
            guard current.stateFingerprint == plan.stateFingerprint,
                  current.caskRemoval?.ownershipFingerprint == removal.ownershipFingerprint,
                  current.caskRemoval?.installedMetadataFingerprint == removal.installedMetadataFingerprint,
                  current.caskRemoval?.entries.map({ "\($0.path)|\($0.disposition.rawValue)|\($0.fingerprint)" })
                    == removal.entries.map({ "\($0.path)|\($0.disposition.rawValue)|\($0.fingerprint)" }) else {
                throw HomebrewClientError.stateChanged
            }
            try caskRemovalScanner.validate(removal)
            try await caskApplicationLifecycle.quitApplications(removal.applicationIdentities)
        } else {
            try await validateFreshness(of: plan)
        }
        let arguments = try arguments(for: plan)
        var actionEnvironment = environment
        actionEnvironment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        if plan.action == .uninstallFormula || plan.action == .uninstallCask || plan.action == .zapCask {
            actionEnvironment["HOMEBREW_NO_AUTOREMOVE"] = "1"
            actionEnvironment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        }
        if plan.caskRemoval != nil { actionEnvironment["HOMEBREW_NO_SUDO"] = "1" }
        for entry in plan.caskRemoval?.entries ?? [] where entry.disposition == .homebrew {
            await progress?.update(entry.path, status: .removing)
        }
        if let removal = plan.caskRemoval {
            try await validateFreshness(of: plan)
            let inventory = try await loadSnapshot(includingOutdated: false)
            guard inventory.sectionErrors[.packages] == nil, inventory.sectionErrors[.configuration] == nil else {
                throw HomebrewClientError.stateChanged
            }
            let caskroom = try await installedCaskroom()
            try await caskApplicationLifecycle.checkApplicationsAreStopped(removal.applicationIdentities)
            // No progress callbacks or quit waits may separate this final installation check from brew.
            let sources = try installedCaskSources(inventory.packages, caskroom: caskroom)
            guard sources.fingerprint == removal.installedMetadataFingerprint else { throw HomebrewClientError.stateChanged }
            for entry in removal.entries where entry.disposition == .homebrew {
                guard try CaskRemovalFileSystem.fingerprint(entry.path) == entry.fingerprint else {
                    throw HomebrewClientError.stateChanged
                }
            }
        }
        let output = try await run(
            arguments,
            environment: actionEnvironment,
            timeout: .seconds(1_800)
        )
        do {
            let snapshot = try await loadSnapshot()
            // Preserve the observed installation state even if later cleanup is interrupted.
            installationRemoved = snapshot.sectionErrors[.packages] == nil
                && !snapshot.packages.contains { plan.targets.contains($0.identity) && $0.isInstalled }
            var cleanupFailures: [CaskRemovalFailure] = []
            if let removal = plan.caskRemoval, output.terminationStatus == 0,
               installationRemoved {
                for entry in removal.entries where entry.disposition == .homebrew {
                    await progress?.update(entry.path, status: CaskRemovalFileSystem.exists(entry.path) ? .retained : .removed)
                }
                do { cleanupFailures = try await cleanCaskRemoval(removal, progress: progress) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    cleanupFailures = removal.entries.filter { $0.disposition == .remove && CaskRemovalFileSystem.exists($0.path) }
                        .map { .init(path: $0.path, error: error) }
                }
            }
            return HomebrewActionResult(
                plan: plan,
                command: output,
                snapshot: snapshot,
                postflightError: nil,
                remainingResidualPaths: plan.caskRemoval == nil ? remainingResidualPaths(from: plan) : [],
                caskRemovalFailures: cleanupFailures
            )
        } catch is CancellationError { throw CancellationError() }
        catch {
            return HomebrewActionResult(
                plan: plan,
                command: output,
                snapshot: nil,
                postflightError: error.localizedDescription,
                remainingResidualPaths: plan.caskRemoval == nil ? remainingResidualPaths(from: plan) : []
            )
        }
    }


    private func cleanCaskRemoval(_ removal: CaskRemovalPlan, progress: CaskRemovalProgressReporter?) async throws -> [CaskRemovalFailure] {
        try await caskApplicationLifecycle.withApplicationsStopped(removal.applicationIdentities, onInvalidation: {}) {
            try await self.cleanConfirmedCaskRemoval(removal, progress: progress)
        }
    }

    private func cleanConfirmedCaskRemoval(_ removal: CaskRemovalPlan, progress: CaskRemovalProgressReporter?) async throws -> [CaskRemovalFailure] {
        let candidates = removal.entries.filter { $0.disposition == .remove }
        var failures: [CaskRemovalFailure] = []
        var authorizationNeeded: [CaskRemovalEntry] = []
        let verification = try caskRemovalScanner.makeVerificationSession(removal)
        for entry in candidates {
            try Task.checkCancellation()
            guard CaskRemovalFileSystem.exists(entry.path) else {
                await progress?.update(entry.path, status: .removed)
                continue
            }
            do {
                await progress?.update(entry.path, status: .removing)
                try await caskApplicationLifecycle.checkApplicationsAreStopped(removal.applicationIdentities)
                // Recheck ownership after all suspension points, immediately before filesystem mutation.
                if entry.category != .homebrewCache {
                    guard try verification.sharedDataRemainsProtected() else {
                        throw HomebrewClientError.stateChanged
                    }
                }
                guard try verification.cacheOwnershipIsUnchanged(entry) else {
                    throw HomebrewClientError.stateChanged
                }
                try CaskRemovalFileSystem.remove(entry, shouldContinue: Task.checkCancellation)
                guard !CaskRemovalFileSystem.exists(entry.path) else { throw HomebrewClientError.stateChanged }
                await progress?.update(entry.path, status: .removed)
            } catch let error as POSIXError where error.code == .EACCES || error.code == .EPERM {
                if caskRemovalAuthorizer != nil,
                   CaskRemovalAuthorizationRequest.allows(entry.path, home: CaskRemovalFileSystem.physicalURL(currentDirectoryURL).path) {
                    authorizationNeeded.append(entry)
                } else {
                    failures.append(.init(path: entry.path, error: error))
                    await progress?.update(entry.path, status: .retained)
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                failures.append(.init(path: entry.path, error: error))
                await progress?.update(entry.path, status: .retained)
            }
        }
        if let caskRemovalAuthorizer, !authorizationNeeded.isEmpty {
            do {
                try await caskApplicationLifecycle.checkApplicationsAreStopped(removal.applicationIdentities)
                let authorizationFailures = try await caskRemovalAuthorizer.remove(authorizationNeeded, home: currentDirectoryURL,
                    removal: removal, applicationLifecycle: caskApplicationLifecycle)
                failures += authorizationFailures
                let failedPaths = Set(authorizationFailures.map(\.path))
                for entry in authorizationNeeded {
                    let removed = !failedPaths.contains(entry.path) && !CaskRemovalFileSystem.exists(entry.path)
                    await progress?.update(entry.path, status: removed ? .removed : .retained)
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                failures += authorizationNeeded.map { .init(path: $0.path, error: error) }
                for entry in authorizationNeeded { await progress?.update(entry.path, status: .retained) }
            }
        }
        return failures
    }


    private func arguments(for plan: HomebrewActionPlan) throws -> [String] {
        switch plan.action {
        case .install:
            return try packageCommand("install", targets: plan.targets)
        case .upgrade:
            return try packageCommand("upgrade", targets: plan.targets)
        case .update:
            return ["update"]
        case .addTap:
            return ["tap", try requiredTapName(plan)]
        case .removeTap:
            return ["untap", try requiredTapName(plan)]
        case .uninstallFormula:
            return try singleTargetCommand(["uninstall", "--formula"], plan: plan, kind: .formula)
        case .uninstallCask:
            return try singleTargetCommand(["uninstall", "--cask"], plan: plan, kind: .cask)
        case .zapCask:
            return try singleTargetCommand(["uninstall", "--cask", "--zap"], plan: plan, kind: .cask)
        }
    }

    private func packageCommand(_ verb: String, targets: [HomebrewPackageIdentity]) throws -> [String] {
        guard !targets.isEmpty else {
            throw HomebrewClientError.invalidPlan("Action plan has no targets")
        }
        let kinds = Set(targets.map(\.kind))
        guard kinds.count == 1, let kind = kinds.first else {
            throw HomebrewClientError.invalidPlan("Cannot mix Formula and Cask targets in a single operation")
        }
        return [verb, kind == .formula ? "--formula" : "--cask"]
            + (try targets.map { try validatedPackageName($0.name) })
    }

    private func singleTargetCommand(
        _ prefix: [String],
        plan: HomebrewActionPlan,
        kind: HomebrewPackageKind
    ) throws -> [String] {
        guard plan.targets.count == 1, plan.targets[0].kind == kind else {
            throw HomebrewClientError.invalidPlan("Uninstall plan target is invalid")
        }
        return prefix + [try validatedPackageName(plan.targets[0].name)]
    }

    private func requiredTapName(_ plan: HomebrewActionPlan) throws -> String {
        guard let name = plan.tapName else {
            throw HomebrewClientError.invalidPlan("Tap operation is missing a tap name")
        }
        return try validatedTapName(name)
    }

    func validatedTapName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !trimmed.hasPrefix("-"),
              trimmed.unicodeScalars.allSatisfy(Self.packageNameCharacters.contains)
        else {
            throw HomebrewClientError.invalidPlan("Tap name must use the owner/repository format")
        }
        return trimmed
    }

    func validatedPackageName(_ name: String) throws -> String {
        guard !name.isEmpty,
              !name.hasPrefix("-"),
              name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              name.unicodeScalars.allSatisfy(Self.packageNameCharacters.contains)
        else {
            throw HomebrewClientError.invalidPlan("Invalid Homebrew package name: \(name)")
        }
        return name
    }

    private static let packageNameCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@+._-/"
    )

}

// Error exits finalize unresolved rows without inventing successful deletion events.
private actor CaskRemovalProgressReporter {
    let entries: [CaskRemovalEntry]
    let handler: CaskRemovalProgressHandler
    private var statuses: [String: CaskRemovalPathStatus] = [:]

    init(entries: [CaskRemovalEntry], handler: @escaping CaskRemovalProgressHandler) {
        self.entries = entries
        self.handler = handler
    }

    func start() async {
        for entry in entries {
            await update(entry.path, status: entry.disposition == .protected ? .retained : .pending)
        }
    }

    func update(_ path: String, status: CaskRemovalPathStatus) async {
        guard statuses[path] != status else { return }
        statuses[path] = status
        await handler(.init(path: path, status: status))
    }

    func finish(paths: [CaskRemovalPathResult]) async {
        for result in paths { await update(result.path, status: result.progress.status) }
        for entry in entries where statuses[entry.path] == .pending || statuses[entry.path] == .removing {
            await update(entry.path, status: .retained)
        }
    }
}
