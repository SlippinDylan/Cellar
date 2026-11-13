import AppKit
import Combine
import PermissionFlow

@MainActor
final class FullDiskAccessGuide: ObservableObject {
    let controller: PermissionFlowController

    init(controller: PermissionFlowController = PermissionFlow.makeController(configuration: .init(
        requiredAppURLs: [Bundle.main.bundleURL],
        promptForAccessibilityTrust: false
    ))) {
        self.controller = controller
    }

    @discardableResult
    func open(locale: Locale) -> Bool {
        controller.setLocaleIdentifier(locale.identifier)
        return controller.authorize(pane: .fullDiskAccess)
    }

    func close() { controller.closePanel() }
}
