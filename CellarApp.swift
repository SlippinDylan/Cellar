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
    private var isTerminatingAsync = false
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
            presentBlockedTerminationNotice()
            return reply
        }
        guard isTerminatingAsync || operationStore.hasActiveReadOnlyOperations || logStore != nil else {
            return reply
        }
        if !isTerminatingAsync {
            isTerminatingAsync = true
            operationStore.beginTermination()
            let message = "Cellar terminating"
            logStore?.record(level: .info, category: "application", message: message)
            Task {
                await operationStore.cancelAndAwaitAllReadOnlyOperations()
                if let logStore {
                    await logStore.flush()
                }
                let canTerminate = !operationStore.hasActiveOperations
                isTerminatingAsync = false
                if !canTerminate {
                    operationStore.cancelTermination()
                    presentBlockedTerminationNotice()
                }
                replyToTermination(canTerminate)
            }
        }
        return .terminateLater
    }

    private func presentBlockedTerminationNotice() {
        operationStore.notifyTerminationBlocked()
        relaunchController.cancelRelaunchRequest()
        guard !AppRuntime.isRunningTests else { return }
        for window in NSApplication.shared.windows where window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApplication.shared.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        operationStore.cancelAllReadOnlyOperations()
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
