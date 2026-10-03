import AppKit
import SwiftUI

@main
struct CellarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.live()
    private let updateController = ApplicationUpdateController()

    var body: some Scene {
        WindowGroup {
            AppRootView(model: model)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            SidebarCommands()
            AppCommands(model: model, updateController: updateController)
        }

        Settings {
            SettingsView(updateController: updateController, relaunchController: .shared,
                         operationStore: model.operationStore)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let operationStore: OperationStore
    private let relaunchController: ApplicationRelaunchController
    private let reopenApplication: () -> Void

    override init() {
        operationStore = .shared
        relaunchController = .shared
        reopenApplication = Self.reopenCurrentApplication
        super.init()
    }

    init(operationStore: OperationStore, relaunchController: ApplicationRelaunchController,
         reopenApplication: @escaping () -> Void) {
        self.operationStore = operationStore
        self.relaunchController = relaunchController
        self.reopenApplication = reopenApplication
        super.init()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reply = AppTerminationPolicy.reply(hasActiveOperations: operationStore.hasActiveOperations)
        if reply == .terminateCancel { relaunchController.cancelRelaunchRequest() }
        return reply
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard relaunchController.consumeRelaunchRequest() else { return }
        reopenApplication()
    }

    private static func reopenCurrentApplication() {
        guard !AppRuntime.isRunningTests else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
    }
}

enum AppTerminationPolicy {
    static func reply(hasActiveOperations: Bool) -> NSApplication.TerminateReply {
        hasActiveOperations ? .terminateCancel : .terminateNow
    }
}
