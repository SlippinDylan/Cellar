import Combine
import Foundation
import Sparkle

@MainActor
final class ApplicationUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    let updateChannel: String
    private let allowedUpdateChannels: Set<String>
    private var updaterController: SPUStandardUpdaterController?

    init(
        updaterEnabled: Bool = (Bundle.main.object(
            forInfoDictionaryKey: "CellarUpdaterEnabled"
        ) as? String)?.localizedCaseInsensitiveCompare("YES") == .orderedSame,
        updateChannel: String = Bundle.main.object(
            forInfoDictionaryKey: "CellarUpdateChannel"
        ) as? String ?? "stable"
    ) {
        self.updateChannel = updateChannel
        allowedUpdateChannels = Self.allowedChannels(for: updateChannel)
        super.init()
        if updaterEnabled {
            let controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: self,
                userDriverDelegate: nil
            )
            updaterController = controller
            observeUpdateAvailability(controller.updater.publisher(for: \.canCheckForUpdates))
        }
    }

    func observeUpdateAvailability<Availability: Publisher>(_ availability: Availability)
        where Availability.Output == Bool, Availability.Failure == Never {
        availability.assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        allowedUpdateChannels
    }

    static func allowedChannels(for channel: String) -> Set<String> {
        switch channel {
        case "stable": []
        case "beta": ["beta"]
        case "alpha": ["alpha", "beta"]
        default: preconditionFailure("Unsupported Cellar update channel: \(channel)")
        }
    }
}
