import AppKit
import SwiftUI
import XCTest
@testable import Cellar

@MainActor
final class LibraryUninstallLayoutTests: XCTestCase {
    func testLongListCannotDisplaceFixedContentOrExceedParentHeightCap() throws {
        for parentHeight in [CGFloat(640), 900] {
            var shortListFrames: [String: CGRect] = [:]
            var shortHeight: CGFloat = 0
            for rowCount in [1, 100] {
                let maximumHeight = parentHeight * 0.7
                let hosting = NSHostingView(rootView: LayoutFixture(rowCount: rowCount, maximumHeight: maximumHeight))
                let size = hosting.fittingSize
                XCTAssertGreaterThan(size.height, 0)
                XCTAssertLessThanOrEqual(size.height, maximumHeight)
                hosting.frame = CGRect(origin: .zero, size: size)
                hosting.layoutSubtreeIfNeeded()
                var frames: [String: CGRect] = [:]
                for name in ["identity", "summary", "list", "footer", "contents"] {
                    let marker = try XCTUnwrap(findMarker(name, in: hosting), "Missing \(name) layout marker")
                    var rect = hosting.convert(marker.bounds, from: marker)
                    if !hosting.isFlipped { rect.origin.y = hosting.bounds.height - rect.maxY }
                    frames[name] = rect
                }
                for name in ["identity", "summary", "list", "footer"] {
                    let frame = try XCTUnwrap(frames[name])
                    XCTAssertGreaterThanOrEqual(frame.minX, -0.5, name)
                    XCTAssertGreaterThanOrEqual(frame.minY, -0.5, name)
                    XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.5, name)
                    XCTAssertLessThanOrEqual(frame.maxY, size.height + 0.5, name)
                }
                let identity = try XCTUnwrap(frames["identity"])
                let summary = try XCTUnwrap(frames["summary"])
                let list = try XCTUnwrap(frames["list"])
                let footer = try XCTUnwrap(frames["footer"])
                XCTAssertEqual(identity.midY, footer.minY / 2, accuracy: 0.5,
                               "The icon and name must stay centered above the footer")
                XCTAssertGreaterThan(list.height, 0)
                XCTAssertLessThanOrEqual(summary.maxY, list.minY)
                XCTAssertLessThanOrEqual(list.maxY, footer.minY)
                XCTAssertEqual(list.maxX, size.width, accuracy: 0.5,
                               "The scroll indicator belongs at the sheet's trailing edge")
                if rowCount == 1 {
                    shortListFrames = frames
                    shortHeight = size.height
                } else {
                    XCTAssertGreaterThan(size.height, shortHeight)
                    XCTAssertEqual(frames["summary"], shortListFrames["summary"],
                                   "List length changed fixed summary placement")
                    XCTAssertGreaterThan(try XCTUnwrap(frames["contents"]).height, list.height)
                }
            }
        }
    }

    func testLockedExecutionHeightIgnoresContentChangesButRespectsSmallerWindow() {
        for rowCount in [1, 100] {
            for maximumHeight in [CGFloat(504), 420] {
                let host = NSHostingView(rootView: LayoutFixture(rowCount: rowCount,
                    maximumHeight: maximumHeight, forcedHeight: 480))
                XCTAssertEqual(host.fittingSize.height, min(480, maximumHeight), accuracy: 0.5)
            }
        }
    }

    func testPathStatusSlotKeepsItsWidthAcrossEveryState() {
        for status in [CaskRemovalPathStatus.pending, .removing, .removed, .retained, .unverified] {
            let host = NSHostingView(rootView: LibraryUninstallPathStatusIndicator(status: status))
            XCTAssertEqual(host.fittingSize.width, 24, accuracy: 0.5)
            XCTAssertEqual(host.fittingSize.height, 20, accuracy: 0.5)
        }
    }

    func testSizeSummaryKeepsDifferentWidthValuesInOneLeadingColumn() throws {
        let host = NSHostingView(rootView: LibraryUninstallSizeSummary(
            applicationSize: Text("1 MB").background(LayoutMarker(name: "applicationSize")),
            estimatedRemoval: Text("1,024.58 MB").background(LayoutMarker(name: "estimatedRemoval"))
        ))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let application = try XCTUnwrap(findMarker("applicationSize", in: host))
        let removal = try XCTUnwrap(findMarker("estimatedRemoval", in: host))
        let applicationFrame = host.convert(application.bounds, from: application)
        let removalFrame = host.convert(removal.bounds, from: removal)
        XCTAssertEqual(applicationFrame.minX, removalFrame.minX, accuracy: 0.5,
                       "Both summary values must start at the same leading edge")
        XCTAssertGreaterThan(removalFrame.width, applicationFrame.width)
        XCTAssertGreaterThan(applicationFrame.minX, 0, "Labels occupy the first column")
    }

    func testActualConfirmationShrinksForShortContentAndKeepsLongContentScrollable() async throws {
        var shortHeight: CGFloat = 0
        for rowCount in [1, 100] {
            let root = FileManager.default.temporaryDirectory.appending(path: "CellarLayoutFixture-\(UUID().uuidString)")
            let runner = ProcessRunner()
            let service = SystemProbeService(runner: runner,
                installer: ManagerSnapshotInstaller(applicationSupportDirectory: root),
                nodeClient: NodeManagerClient(runner: runner, environmentResolver: .init(homeDirectory: root)),
                shellClient: ShellManagerClient(runner: runner), environmentResolver: .init(homeDirectory: root))
            let removal = CaskRemovalPlan(displayName: "Fixture App", appURL: nil,
                entries: (0..<rowCount).map { index in
                    CaskRemovalEntry(path: "/fixture/Library/Caches/com.fixture.app/\(index)/cache.db",
                                     category: .cache, estimatedBytes: 1_024, disposition: .remove, fingerprint: "fixture")
                }, warnings: [], ownershipFingerprint: "fixture")
            let model = AppModel(service: service, operationStore: OperationStore(), batchProvider: FakeBatchProvider(caskRemoval: removal))
            let uninstall = LibraryUninstallModel(model: model, loadIconData: { _ in nil })
            await uninstall.prepare(.homebrew(.init(name: "fixture-app", kind: .cask)))
            XCTAssertNotNil(uninstall.confirmation)
            let ready = expectation(description: "Actual confirmation has a bounded list viewport")
            var scrollSize = CGSize.zero
            var didReport = false
            let maximumHeight: CGFloat = 640 * 0.7
            let host = NSHostingView(rootView: LibraryUninstallConfirmation(uninstall: uninstall, maximumHeight: maximumHeight)
                .onScrollGeometryChange(for: CGSize.self) { geometry in
                    CGSize(width: geometry.contentSize.height, height: geometry.containerSize.height)
                } action: { _, size in
                    scrollSize = size
                    if size.height > 0 && !didReport { didReport = true; ready.fulfill() }
                })
            let size = host.fittingSize
            XCTAssertGreaterThan(size.height, 0)
            XCTAssertLessThanOrEqual(size.height, maximumHeight)
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            await fulfillment(of: [ready], timeout: 3)
            if rowCount == 1 {
                shortHeight = size.height
                XCTAssertLessThan(shortHeight, maximumHeight)
            } else {
                XCTAssertGreaterThan(size.height, shortHeight)
                XCTAssertGreaterThan(scrollSize.width, scrollSize.height,
                                     "All fixture paths must remain available through the bounded scroll viewport")
            }
            withExtendedLifetime(host) {}
        }
    }

    private func findMarker(_ name: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == name { return view }
        for child in view.subviews {
            if let found = findMarker(name, in: child) { return found }
        }
        return nil
    }
}

private struct LayoutFixture: View {
    let rowCount: Int
    let maximumHeight: CGFloat
    var forcedHeight: CGFloat? = nil

    var body: some View {
        LibraryUninstallLayout(maximumHeight: maximumHeight, forcedHeight: forcedHeight) {
            VStack(spacing: 12) {
                Color.blue.frame(width: 88, height: 88)
                Text("Fixture App").font(.headline)
            }
            .background(LayoutMarker(name: "identity"))
            VStack(alignment: .leading, spacing: 12) {
                Text("Uninstall Software").font(.title2.bold())
                LibraryUninstallSizeSummary(applicationSize: Text("120 MB"), estimatedRemoval: Text("180 MB"))
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(LayoutMarker(name: "summary"))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(0..<rowCount, id: \.self) { index in
                        Text("/fixture/Library/Application Support/Fixture App/\(index)/cache.db")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LayoutMarker(name: "contents"))
                .padding(.trailing, 24)
            }
            .clipped()
            .background(LayoutMarker(name: "list"))
            HStack {
                Spacer()
                Button("Cancel") {}
                Button("Uninstall", role: .destructive) {}
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .fixedSize(horizontal: false, vertical: true)
            .background(LayoutMarker(name: "footer"))
        }
    }
}

private struct LayoutMarker: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(name)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
