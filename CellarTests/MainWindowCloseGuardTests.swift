import AppKit
import SwiftUI
import XCTest
@testable import Cellar

@MainActor
final class MainWindowCloseGuardTests: XCTestCase {
    func testMainWindowRejectsUserCloseWhileWorkingAndAllowsItWhenIdle() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarCloseGuard-\(UUID().uuidString)")
        let runner = ProcessRunner()
        let service = SystemProbeService(runner: runner,
            installer: ManagerSnapshotInstaller(applicationSupportDirectory: root),
            nodeClient: NodeManagerClient(runner: runner, environmentResolver: .init(homeDirectory: root)),
            shellClient: ShellManagerClient(runner: runner), environmentResolver: .init(homeDirectory: root))
        let operations = OperationStore()
        let model = AppModel(service: service, operationStore: operations, batchProvider: FakeBatchProvider())
        model.selectedDestination = .library
        let existingWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let sceneID = "CellarCloseGuard-\(UUID().uuidString)"
        // Window behaviors are consumed by a SwiftUI Scene, not a standalone NSHostingController.
        let representation = NSHostingSceneRepresentation {
            Window("Cellar Close Guard Fixture", id: sceneID) {
                AppRootView(model: model, updateController: ApplicationUpdateController(updaterEnabled: false))
            }
            .defaultSize(width: 1_080, height: 720)
        }
        NSApplication.shared.addSceneRepresentation(representation)
        representation.environment.openWindow(id: sceneID)
        await renderWindowChanges()
        let window = try XCTUnwrap(NSApplication.shared.windows.first {
            !existingWindows.contains(ObjectIdentifier($0)) && !($0 is NSPanel)
        })
        defer { window.orderOut(nil); window.close() }
        XCTAssertTrue(window.isVisible)
        let originalDelegate = window.delegate

        let operationID = operations.begin()
        await renderWindowChanges()
        window.performClose(nil)
        XCTAssertTrue(window.isVisible, "Red close and Command-W must preserve the task's main window")
        XCTAssertTrue(window.delegate === originalDelegate, "Close protection must preserve the window's delegate")

        let panel = NSPanel(contentRect: CGRect(x: 100, y: 100, width: 300, height: 200),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.orderFront(nil)
        panel.performClose(nil)
        XCTAssertFalse(panel.isVisible, "Main-window task protection must not affect independent panels")

        operations.end(operationID)
        window.orderFront(nil)
        await renderWindowChanges()
        window.performClose(nil)
        XCTAssertFalse(window.isVisible, "Completing the task must restore normal user closing")
        XCTAssertTrue(window.delegate === originalDelegate)
    }

    private func renderWindowChanges() async {
        let rendered = expectation(description: "Window behavior updated")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { rendered.fulfill() }
        await fulfillment(of: [rendered], timeout: 3)
    }
}
