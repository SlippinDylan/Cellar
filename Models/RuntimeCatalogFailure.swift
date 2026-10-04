import Foundation

enum RuntimeCatalogFailure: Equatable, Sendable {
    case offline, network, invalidResponse, unavailable, cancelled

    init(error: Error) {
        if error is CancellationError { self = .cancelled }
        else if let error = error as? URLError {
            self = switch error.code {
            case .notConnectedToInternet: .offline
            case .cancelled: .cancelled
            default: .network
            }
        } else if error is DecodingError { self = .invalidResponse }
        else if let error = error as? CatalogSourceError {
            self = switch error {
            case .httpStatus: .unavailable
            case .invalidURL, .invalidQuery, .invalidResponse, .responseTooLarge: .invalidResponse
            }
        } else { self = .unavailable }
    }

    var message: LocalizedStringResource {
        switch self {
        case .offline: LocalizedStringResource("Node versions could not be loaded while offline. Connect to the internet and try again.")
        case .network: LocalizedStringResource("The official Node service could not be reached. Check the connection and try again.")
        case .invalidResponse: LocalizedStringResource("The official Node version list could not be verified. Try loading it again.")
        case .unavailable: LocalizedStringResource("The official Node version list is unavailable. Try again later.")
        case .cancelled: LocalizedStringResource("Loading Node versions was cancelled. You can try again.")
        }
    }
}
