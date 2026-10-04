import Foundation
import XCTest
@testable import Cellar

final class CatalogCardViewTests: XCTestCase {
    func testVerificationProgressIsExplicitAndDecorativeSpinnerIsHidden() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "Features/Catalog/CatalogCardView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("state.progress == .verifying"))
        XCTAssertTrue(source.contains("ActivityTaskStage.reconciling.title"))
        XCTAssertTrue(source.contains(".accessibilityHidden(true)"))
    }

    func testProviderStatusAndActionLabelsAreExplicitAndLocalized() {
        XCTAssertEqual(localized(CatalogProviderScope.homebrewFormula.cardTitle), "Homebrew · Formula")
        XCTAssertEqual(localized(CatalogProviderScope.homebrewCask.cardTitle), "Homebrew · Cask")
        XCTAssertEqual(localized(CatalogProviderScope.npm.cardTitle), "npm")
        for status in [SemanticVersionStatus.behind, .current, .ahead, .unknown] {
            XCTAssertFalse(localized(status.cardTitle).isEmpty)
            XCTAssertFalse(status.cardSymbol.isEmpty)
        }
        for (language, expected) in [("en", "Update"), ("zh-Hans", "更新"), ("zh-Hant", "更新")] {
            XCTAssertEqual(localized(CatalogCardAction.update.cardTitle, language: language), expected)
        }
    }

    func testCardIsInertByConstructionWithTwoLineDescriptionAndExplicitControls() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "Features/Catalog/CatalogCardView.swift"), encoding: .utf8)
        for forbidden in ["NavigationLink", ".onTapGesture", ".onHover", ".contextMenu", "AsyncImage", "Process("] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
        XCTAssertTrue(source.contains(".lineLimit(2)"))
        XCTAssertTrue(source.contains(".truncationMode(.tail)"))
        XCTAssertTrue(source.contains("Link(destination:"))
        XCTAssertTrue(source.contains("if let action = state.primaryAction"))
        XCTAssertTrue(source.contains("state.nodeEnvironment"))
        XCTAssertTrue(source.contains("state.progress"))
        XCTAssertTrue(source.contains(".accessibilityLabel"))
        XCTAssertTrue(source.contains("LazyVGrid"))
        XCTAssertTrue(source.contains(".adaptive(minimum:"))
        XCTAssertTrue(source.contains("ForEach(states)"))
    }

    func testCardPreservesNPMEnvironmentAndProgressAndRejectsUnsafeWebsites() throws {
        let environment = NodeEnvironmentContext(identifier: "nvm:v22.0.0", nodeVersion: "v22.0.0", npmVersion: "10.0.0")
        let identity = CatalogItemIdentity.npm(.init(name: "typescript", environment: environment))
        let unsafe = try XCTUnwrap(URL(string: "file:///fixture/private"))
        let state = try XCTUnwrap(CatalogCardState(identity: identity, displayName: "typescript", description: "fixture", currentVersion: "1.0.0", availableVersion: "2.0.0", versionStatus: .behind, websiteURL: unsafe, progress: .queued, primaryAction: .update))
        XCTAssertEqual(state.id, identity)
        XCTAssertEqual(state.nodeEnvironment, environment)
        XCTAssertEqual(state.progress, .queued)
        XCTAssertEqual(state.primaryAction, .update)
        XCTAssertNil(state.websiteURL)
    }

    private func localized(_ resource: LocalizedStringResource, language: String = "en") -> String {
        var resource = resource
        resource.locale = Locale(identifier: language)
        return String(localized: resource)
    }
}
