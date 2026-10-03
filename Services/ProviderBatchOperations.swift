import Foundation

struct ProviderBatchOperations: BatchOperationProviding {
    let service: SystemProbeService

    func planHomebrew(_ identity: HomebrewPackageIdentity, operation: BatchOperation) async throws -> HomebrewActionPlan {
        switch operation {
        case .install:
            try await service.planHomebrewInstall(identity)
        case .update:
            try await service.planHomebrewUpgrade([identity])
        case .uninstall:
            switch identity.kind {
            case .formula: try await service.planHomebrewFormulaUninstall(identity.name)
            case .cask: try await service.planHomebrewCaskUninstall(identity.name, zap: false)
            }
        }
    }

    func executeHomebrew(_ plan: HomebrewActionPlan) async throws -> HomebrewActionResult {
        try await service.executeHomebrew(plan)
    }

    func refreshHomebrew() async throws -> HomebrewStatus {
        let managers = try await service.installManagers()
        return try await service.loadHomebrew(snapshot: managers)
    }

    func planNPM(_ identity: NPMPackageIdentity, operation: BatchOperation) async throws -> NodeActionPlan {
        let managers = try await service.installManagers()
        return try await service.planNPMPackage(identity, action: operation.nodeAction, snapshot: managers)
    }

    func executeNPM(_ plan: NodeActionPlan, environment: NodeEnvironmentContext) async throws -> NodeOperationResult {
        let managers = try await service.installManagers()
        return try await service.executeNPMPackage(plan, environment: environment, snapshot: managers)
    }

    func refreshNPM(_ environment: NodeEnvironmentContext) async throws -> NodeSnapshot {
        let managers = try await service.installManagers()
        return try await service.loadNPMPackageEnvironment(environment, snapshot: managers)
    }
}
