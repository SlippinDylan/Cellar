import Foundation

extension ActivityItemReason {
    static func postWriteStatus(error: Error) -> BatchItemStatus? {
        guard case BridgeError.managerFailure(let code, _) = error else { return nil }
        return verificationStatus(code: code)
    }

    init(error: Error, preparing: Bool = false) {
        if error is CancellationError { self = .cancelledByUser; return }
        if error is CaskRemovalAuthorizationError { self = .authorizationFailed; return }
        if let error = error as? CaskApplicationLifecycleError {
            if case .identityMismatch = error { self = .stateChanged }
            else { self = .applicationRunning }
            return
        }
        if let error = error as? URLError { self = error.code == .cancelled ? .cancelledByUser : .network; return }
        if let error = error as? HomebrewSetupError {
            self = switch error.failure {
            case .releaseMetadata, .download, .rateLimited: .network
            case .temporaryFile: .permission
            case .installationInProgress, .commandLineToolsRequired: .unavailable
            case .installationTarget: .stateChanged
            case .digestMissing, .digestInvalid, .digestMismatch, .packageSignature, .gatekeeper, .systemOpen: .stateUnavailable
            }
            return
        }
        if let error = error as? CocoaError {
            switch error.code {
            case .fileReadNoPermission, .fileWriteNoPermission: self = .permission
            case .fileNoSuchFile, .fileReadNoSuchFile: self = .unavailable
            default: self = .stateUnavailable
            }
            return
        }
        if let error = error as? BridgeError {
            switch error {
            case .executableNotFound: self = .unavailable
            case .processTimedOut: self = .timedOut
            case .invalidOutput, .unsupportedSchema: self = .stateUnavailable
            case .managerFailure(let code, _):
                if Self.verificationStatus(code: code) != nil { self = .stateUnavailable }
                else if ["plan-stale", "plan-expired", "npm-update-not-behind"].contains(code) || code.hasSuffix("-changed") { self = .stateChanged }
                else if code.contains("permission") { self = .permission }
                else if code.hasSuffix("-unavailable") || code.hasSuffix("-not-found") { self = .unavailable }
                else { self = preparing ? .preparationFailed : .providerFailure }
            }
            return
        }
        if let error = error as? HomebrewClientError {
            switch error {
            case .stateChanged: self = .stateChanged
            case .scanIncomplete: self = .scanIncomplete
            case .executableNotFound: self = .unavailable
            case .alreadyInstalled: self = .alreadyInstalled
            case .invalidJSON, .outputTruncated: self = .stateUnavailable
            case .invalidPlan: self = .preparationFailed
            case .commandFailed: self = preparing ? .preparationFailed : .providerFailure
            }
            return
        }
        if let error = error as? BatchOperationError {
            switch error {
            case .planUnavailable: self = .stateChanged
            case .invalidPlan, .conflictingVersions, .protectedNode: self = .preparationFailed
            case .busy: self = .unavailable
            case .reconciliationUnavailable: self = .stateUnavailable
            }
            return
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain && [1, 13].contains(nsError.code) { self = .permission }
        else { self = preparing ? .preparationFailed : .providerFailure }
    }
}

extension NodeOperationResult {
    var activityReason: ActivityItemReason? {
        switch batchItemStatus {
        case .skipped: .alreadySatisfied
        case .succeeded: nil
        case .cancelled: .cancelledByUser
        case .unknown: .stateUnavailable
        case .partiallySucceeded: detail == "residue-detected" ? .residueDetected : .stateUnavailable
        case .failed: .init(error: BridgeError.managerFailure(code: detail ?? "provider-failure", detail: nil))
        }
    }
}

extension ActivityStoreError {
    var message: LocalizedStringResource {
        switch self {
        case .invalidSummary: LocalizedStringResource("This task result could not be displayed safely.")
        }
    }
}
