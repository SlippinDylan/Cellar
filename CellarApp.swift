import AppKit
import SwiftUI

@main
enum CellarEntryPoint {
    @MainActor static func main() {
        if let status = CaskRemovalPrivilegedMode.run(arguments: CommandLine.arguments) {
            exit(status)
        }
        CellarApp.main()
    }
}

struct CellarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.live()
    private let updateController = ApplicationUpdateController()

    var body: some Scene {
        WindowGroup(id: AppScene.mainWindowID, for: MainWindowIdentity.self) { _ in
            AppRootView(model: model, updateController: updateController)
                .onAppear { appDelegate.logStore = model.logStore }
                .frame(minWidth: 1080, minHeight: 720)
        } defaultValue: {
            .main
        }
        .defaultSize(width: 1080, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            AppCommands(model: model, updateController: updateController)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var logStore: FileLogStore?
    private var isFlushingLogs = false
    private let operationStore: OperationStore
    private let relaunchController: ApplicationRelaunchController
    private let reopenApplication: () -> Void
    private let replyToTermination: (Bool) -> Void

    override init() {
        operationStore = .shared
        relaunchController = .shared
        reopenApplication = Self.reopenCurrentApplication
        replyToTermination = { NSApplication.shared.reply(toApplicationShouldTerminate: $0) }
        super.init()
    }

    init(operationStore: OperationStore, relaunchController: ApplicationRelaunchController,
         replyToTermination: @escaping (Bool) -> Void = { NSApplication.shared.reply(toApplicationShouldTerminate: $0) },
         reopenApplication: @escaping () -> Void) {
        self.operationStore = operationStore
        self.relaunchController = relaunchController
        self.reopenApplication = reopenApplication
        self.replyToTermination = replyToTermination
        super.init()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reply = AppTerminationPolicy.reply(hasActiveOperations: operationStore.hasActiveOperations)
        if reply == .terminateCancel {
            relaunchController.cancelRelaunchRequest()
            return reply
        }
        guard let logStore else { return reply }
        if !isFlushingLogs {
            isFlushingLogs = true
            let message = "Cellar terminating"
            logStore.record(level: .info, category: "application", message: message)
            Task {
                await logStore.flush()
                let canTerminate = !operationStore.hasActiveOperations
                if !canTerminate {
                    isFlushingLogs = false
                    relaunchController.cancelRelaunchRequest()
                }
                replyToTermination(canTerminate)
            }
        }
        return .terminateLater
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
