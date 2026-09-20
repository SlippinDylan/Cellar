import AppKit
import SwiftUI

@main
struct CellarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.live()

    var body: some Scene {
        WindowGroup {
            AppRootView(model: model)
        }
        .defaultSize(width: 1080, height: 720)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppTerminationPolicy.reply(hasActiveOperations: OperationStore.shared.hasActiveOperations)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

enum AppTerminationPolicy {
    static func reply(hasActiveOperations: Bool) -> NSApplication.TerminateReply {
        hasActiveOperations ? .terminateCancel : .terminateNow
    }
}
