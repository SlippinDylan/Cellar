import AppKit
import SwiftUI
import XCTest
@testable import Cellar

@MainActor
final class TaskFeedbackLayoutTests: XCTestCase {
    func testEmptyShortAndDismissedFeedbackUseOnlyTheRequiredSpace() async {
        let model = AppModel.live()
        let empty = expectation(description: "Empty feedback occupies no height")
        let short = expectation(description: "Short feedback uses its natural height")
        let dismissed = expectation(description: "Dismissed feedback occupies no height")
        var phase = 0
        var shortHeight: CGFloat = 0
        let host = NSHostingView(rootView: TaskFeedbackView(model: model, maximumHeight: 300)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                switch phase {
                case 0 where height == 0: phase = 1; empty.fulfill()
                case 1 where height > 0: shortHeight = height; phase = 2; short.fulfill()
                case 2 where height == 0: phase = 3; dismissed.fulfill()
                default: break
                }
            })
        host.frame = NSRect(x: 0, y: 0, width: 860, height: 650)
        host.layoutSubtreeIfNeeded()
        await fulfillment(of: [empty], timeout: 3)
        model.nodeOperationError = "A short fixture error"
        await fulfillment(of: [short], timeout: 3)
        XCTAssertGreaterThan(shortHeight, 0)
        XCTAssertLessThan(shortHeight, 120)
        model.nodeOperationError = nil
        await fulfillment(of: [dismissed], timeout: 3)
        withExtendedLifetime(host) {}
    }

    func testMultipleFailedGroupsRemainScrollableAndLeaveSpaceForPage() async throws {
        let operations = OperationStore()
        let store = ActivityStore(operationStore: operations)
        let task = operations.begin()
        let environment = NodeEnvironmentContext(identifier: "fixture", nodeVersion: "v22.0.0", npmVersion: "10.0.0")
        for scope in [ActivityScope.homebrew(.formula), .homebrew(.cask), .npm(environment)] {
            let names = (1...30).map { "package-\($0)" }
            try store.record(.init(id: UUID(), operation: .update, scope: scope, targetDisplayNames: names,
                                   date: Date(), status: .failed,
                                   itemOutcomes: names.map { .init(displayName: $0, status: .failed, reason: .network) }))
        }
        operations.end(task)
        let model = AppModel(service: AppModel.live().service, operationStore: operations, activityStore: store)
        let ready = expectation(description: "Feedback has a bounded nonempty viewport")
        var feedbackHeight: CGFloat = 0
        var pageHeight: CGFloat = 0
        var hasScrollableResults = false
        var scrollSize = CGSize.zero
        var didReport = false
        let host = NSHostingView(rootView: GeometryReader { geometry in
            VStack(spacing: 0) {
                TaskFeedbackView(model: model, maximumHeight: geometry.size.height * 0.45)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        feedbackHeight = height
                    }
                    .onScrollGeometryChange(for: CGSize.self) { geometry in
                        CGSize(width: geometry.contentSize.height, height: geometry.containerSize.height)
                    } action: { _, size in
                        scrollSize = size
                        let scrollable = size.height > 0 && size.width > size.height * 2
                        hasScrollableResults = scrollable
                        if scrollable && !didReport { didReport = true; ready.fulfill() }
                    }
                ScrollView { Text("Page content").frame(minHeight: 500) }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeight = $0 }
            }
        })
        host.frame = NSRect(x: 0, y: 0, width: 860, height: 650)
        host.layoutSubtreeIfNeeded()
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertLessThanOrEqual(feedbackHeight, 650 * 0.45 + 1)
        XCTAssertGreaterThanOrEqual(pageHeight, 650 * 0.55 - 1)
        XCTAssertTrue(hasScrollableResults,
                      "The full result list must remain available: document \(scrollSize.width), viewport \(scrollSize.height)")
        withExtendedLifetime(host) {}
    }
}
