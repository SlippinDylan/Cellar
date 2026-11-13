import AppKit
import SwiftUI
import XCTest
@testable import Cellar

@MainActor
final class LibraryUninstallSheetTests: XCTestCase {
    func testWindowOwnedSheetSurvivesNavigationAwayFromLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarSheetOwner-\(UUID().uuidString)")
        let runner = ProcessRunner()
        let service = SystemProbeService(runner: runner,
            installer: ManagerSnapshotInstaller(applicationSupportDirectory: root),
            nodeClient: NodeManagerClient(runner: runner, environmentResolver: .init(homeDirectory: root)),
            shellClient: ShellManagerClient(runner: runner), environmentResolver: .init(homeDirectory: root))
        let removal = CaskRemovalPlan(displayName: "Fixture App", appURL: nil, entries: [], warnings: [], ownershipFingerprint: "fixture")
        let provider = SheetCaskProvider(removal: removal, started: {})
        await provider.finishPlanning()
        let model = AppModel(service: service, operationStore: OperationStore(), batchProvider: provider)
        model.selectedDestination = .library
        let uninstall = LibraryUninstallModel(model: model, loadIconData: { _ in nil })
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1_080, height: 720),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: AppRootView(model: model,
            updateController: ApplicationUpdateController(updaterEnabled: false), uninstall: uninstall))
        defer {
            uninstall.dismissConfirmation()
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
            window.close()
        }
        window.orderFront(nil)
        await uninstall.prepare(.homebrew(.init(name: "fixture", kind: .cask)))
        let attached = expectation(description: "Window sheet attached")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { attached.fulfill() }
        await fulfillment(of: [attached], timeout: 3)
        let sheet = try XCTUnwrap(window.attachedSheet)
        model.selectedDestination = .about
        let navigated = expectation(description: "Navigation rendered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { navigated.fulfill() }
        await fulfillment(of: [navigated], timeout: 3)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.attachedSheet === sheet, "Navigation must not remove the active uninstall owner")
        await uninstall.confirmUninstall()
        XCTAssertTrue(uninstall.hasFinished)
        XCTAssertTrue(window.attachedSheet === sheet, "The finished review remains on the window until OK")
    }

    func testPresentedLoadingSheetResizesForCompletedLongPlanWithoutClippingFixedContent() async throws {
        let started = expectation(description: "Fake Cask planning started")
        let appeared = expectation(description: "SwiftUI attached the loading sheet")
        let removal = CaskRemovalPlan(displayName: "Fixture App", appURL: nil,
            entries: (0..<100).map { index in
                CaskRemovalEntry(path: "/fixture/Library/Caches/com.fixture.app/\(index)/cache.db",
                                 category: .cache, estimatedBytes: 1_024, disposition: .remove, fingerprint: "fixture")
            }, warnings: [], ownershipFingerprint: "fixture")
        let provider = SheetCaskProvider(removal: removal, started: { started.fulfill() })
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarSheetFixture-\(UUID().uuidString)")
        let runner = ProcessRunner()
        let service = SystemProbeService(runner: runner,
            installer: ManagerSnapshotInstaller(applicationSupportDirectory: root),
            nodeClient: NodeManagerClient(runner: runner, environmentResolver: .init(homeDirectory: root)),
            shellClient: ShellManagerClient(runner: runner), environmentResolver: .init(homeDirectory: root))
        let model = AppModel(service: service, operationStore: OperationStore(), batchProvider: provider)
        let uninstall = LibraryUninstallModel(model: model, loadIconData: { _ in nil })
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1_080, height: 720),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Cellar Uninstall Sheet Fixture"
        let maximumHeight = window.contentLayoutRect.height * 0.7
        let geometry = SheetGeometry()
        window.contentViewController = NSHostingController(rootView: SheetFixture(uninstall: uninstall,
            maximumHeight: maximumHeight, appeared: appeared, geometry: geometry))
        defer {
            uninstall.dismissConfirmation()
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
            window.close()
        }
        window.orderFront(nil)
        let preparation = Task { await uninstall.prepare(.homebrew(.init(name: "fixture-app", kind: .cask))) }
        await fulfillment(of: [started, appeared], timeout: 4)
        XCTAssertTrue(uninstall.isPreparing)
        let sheet = try XCTUnwrap(window.attachedSheet)
        let loadingHeight = sheet.contentLayoutRect.height
        let resized = expectation(description: "Existing sheet resized to the completed plan height")
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: sheet, queue: .main) { _ in
            MainActor.assumeIsolated {
                if sheet.contentLayoutRect.height >= maximumHeight - 1, !geometry.reportedResize {
                    geometry.reportedResize = true
                    resized.fulfill()
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        await provider.finishPlanning()
        await preparation.value
        await fulfillment(of: [resized], timeout: 4)
        XCTAssertNotNil(uninstall.confirmation)
        XCTAssertFalse(uninstall.isPreparing)
        XCTAssertGreaterThan(sheet.contentLayoutRect.height, loadingHeight)
        XCTAssertEqual(sheet.contentLayoutRect.height, maximumHeight, accuracy: 1)
        XCTAssertLessThanOrEqual(sheet.contentLayoutRect.height, maximumHeight + 1)
        XCTAssertEqual(geometry.contentSize.height, maximumHeight, accuracy: 1)
        let hosting = try XCTUnwrap(sheet.contentView)
        XCTAssertGreaterThanOrEqual(hosting.bounds.height + 1, geometry.contentSize.height,
                                    "AppKit's sheet host must cover the entire SwiftUI content")
        if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(filePath: "/tmp/cellar-uninstall-sheet-fixture.png"))
            }
        }
        hosting.layoutSubtreeIfNeeded()
        let visibleBounds = hosting.bounds.insetBy(dx: -1, dy: -1)
        XCTAssertFalse(geometry.contentRect.isEmpty)
        XCTAssertTrue(visibleBounds.contains(geometry.contentRect),
                      "The entire SwiftUI root must be visible: root \(geometry.contentRect), host \(visibleBounds)")
        let visibleFrame = sheet.convertToScreen(sheet.contentLayoutRect).insetBy(dx: -1, dy: -1)
        // Without an AX client, SwiftUI may not materialize title/button AX nodes. The selectable name is native.
        // Root containment covers presentation clipping; the separate Layout fixture checks all fixed regions.
        for text in ["Fixture App"] {
            let element = try XCTUnwrap(accessibilityElement(text: text, in: hosting), "Missing fixed content: \(text)")
            let frame = element.accessibilityFrame()
            XCTAssertFalse(frame.isEmpty, text)
            XCTAssertTrue(visibleFrame.contains(frame), "Fixed content \(text) is clipped: \(frame), visible: \(visibleFrame)")
        }
        let confirmedHeight = sheet.contentLayoutRect.height
        await uninstall.confirmUninstall()
        hosting.layoutSubtreeIfNeeded()
        XCTAssertTrue(uninstall.hasFinished)
        XCTAssertNotNil(uninstall.presentedItem, "The completed Cask review stays open until OK")
        XCTAssertTrue(window.attachedSheet === sheet)
        XCTAssertEqual(sheet.contentLayoutRect.height, confirmedHeight, accuracy: 1,
                       "Execution and completion must preserve the confirmed sheet height")
    }

    private func accessibilityElement(text: String, in root: NSView) -> (any NSAccessibilityProtocol)? {
        var pending: [Any] = [root]
        var visited = Set<ObjectIdentifier>()
        while let next = pending.popLast(), visited.count < 4_000 {
            let object = next as AnyObject
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            // AppKit's sheet content view can be an ignored wrapper around the real hosting view.
            if let view = next as? NSView { pending.append(contentsOf: view.subviews) }
            guard let element = next as? any NSAccessibilityProtocol else { continue }
            let labels = [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityValue() as? String]
            let children = element.accessibilityChildren() ?? []
            if labels.contains(where: { $0 == text }) { return element }
            pending.append(contentsOf: children)
        }
        return nil
    }

}

@MainActor
private final class SheetGeometry {
    var contentRect = CGRect.zero
    var contentSize: CGSize { contentRect.size }
    var reportedResize = false
    var reportedAppearance = false
}

private struct SheetFixture: View {
    @ObservedObject var uninstall: LibraryUninstallModel
    let maximumHeight: CGFloat
    let appeared: XCTestExpectation
    let geometry: SheetGeometry

    var body: some View {
        Color.clear
            .sheet(isPresented: Binding(get: { uninstall.presentedItem != nil }, set: { if !$0 { uninstall.dismissConfirmation() } })) {
                LibraryUninstallConfirmation(uninstall: uninstall, maximumHeight: maximumHeight)
                    .environment(\.locale, Locale(identifier: "en"))
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { geometry.contentRect = $0 }
                    .onAppear {
                        if !geometry.reportedAppearance { geometry.reportedAppearance = true; appeared.fulfill() }
                    }
            }
    }
}

private actor SheetCaskProvider: BatchOperationProviding {
    private let base: FakeBatchProvider
    private let started: @Sendable () -> Void
    private let gate: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(removal: CaskRemovalPlan, started: @escaping @Sendable () -> Void) {
        base = FakeBatchProvider(caskRemoval: removal)
        self.started = started
        let stream = AsyncStream.makeStream(of: Void.self)
        gate = stream.stream
        continuation = stream.continuation
    }

    func finishPlanning() { continuation.yield(); continuation.finish() }

    func renewHomebrew(_ plan: HomebrewActionPlan) async throws -> HomebrewActionPlan? { try await base.renewHomebrew(plan) }
    func renewNPM(_ plan: NodeActionPlan, environment: NodeEnvironmentContext) async throws -> NodeActionPlan? { try await base.renewNPM(plan, environment: environment) }

    func planHomebrew(_ identity: HomebrewPackageIdentity, operation: BatchOperation) async throws -> HomebrewActionPlan {
        started()
        for await _ in gate { break }
        try Task.checkCancellation()
        return try await base.planHomebrew(identity, operation: operation)
    }

    func executeHomebrew(_ plan: HomebrewActionPlan) throws -> HomebrewActionResult { throw BatchOperationError.invalidPlan }
    func refreshHomebrew() throws -> HomebrewStatus { throw BatchOperationError.invalidPlan }
    func planNPM(_ identity: NPMPackageIdentity, operation: BatchOperation) throws -> NodeActionPlan { throw BatchOperationError.invalidPlan }
    func executeNPM(_ plan: NodeActionPlan, environment: NodeEnvironmentContext) throws -> NodeOperationResult { throw BatchOperationError.invalidPlan }
    func refreshNPM(_ environment: NodeEnvironmentContext) throws -> NodeSnapshot { throw BatchOperationError.invalidPlan }
    func planNodeUninstall(_ identity: NodeRuntimeIdentity) throws -> NodeActionPlan { throw BatchOperationError.invalidPlan }
    func executeNodeUninstall(_ plan: NodeActionPlan, environment: NodeEnvironmentContext) throws -> NodeOperationResult { throw BatchOperationError.invalidPlan }
}
