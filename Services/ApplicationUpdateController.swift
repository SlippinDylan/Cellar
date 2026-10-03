import Foundation
import Sparkle

@MainActor
final class ApplicationUpdateController: NSObject, SPUUpdaterDelegate {
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
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: self,
                userDriverDelegate: nil
            )
        }
    }

    var canCheckForUpdates: Bool {
        updaterController?.updater.canCheckForUpdates == true
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
