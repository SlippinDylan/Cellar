import XCTest
@testable import Cellar

final class CatalogDomainModelsTests: XCTestCase {
    func testUnifiedIdentityKeepsProviderAndNodeEnvironmentDistinct() throws {
        let formula = CatalogItemIdentity.homebrew(.init(name: "demo", kind: .formula))
        let cask = CatalogItemIdentity.homebrew(.init(name: "demo", kind: .cask))
        let node20 = NodeEnvironmentContext(
            identifier: "nvm:v20.18.0",
            nodeVersion: "v20.18.0",
            npmVersion: "10.8.2"
        )
        let node22 = NodeEnvironmentContext(
            identifier: "nvm:v22.12.0",
            nodeVersion: "v22.12.0",
            npmVersion: "10.9.0"
        )
        let npm20 = CatalogItemIdentity.npm(.init(name: "typescript", environment: node20))
        let npm22 = CatalogItemIdentity.npm(.init(name: "typescript", environment: node22))

        XCTAssertNotEqual(formula, cask)
        XCTAssertNotEqual(npm20, npm22)
        XCTAssertEqual(formula.providerScope, .homebrew(.formula))
        XCTAssertEqual(cask.providerScope, .homebrew(.cask))
        XCTAssertEqual(npm20.providerScope, .npm)

        let card = try XCTUnwrap(CatalogCardState(
            identity: npm20,
            displayName: "TypeScript",
            description: "TypeScript is JavaScript with syntax for types.",
            currentVersion: "5.6.2",
            availableVersion: "5.7.2",
            versionStatus: .behind,
            websiteURL: try XCTUnwrap(URL(string: "https://www.npmjs.com/package/typescript")),
            progress: .idle,
            primaryAction: .update
        ))
        XCTAssertEqual(card.identity, npm20)
        XCTAssertEqual(card.nodeEnvironment, node20)
    }

    func testHomebrewAndOnlineVersionStatesPreserveDistinctSemanticsAndPayloads() throws {
        let installation = HomebrewInstallation(
            executablePath: "/opt/homebrew/bin/brew",
            version: "5.0.0"
        )
        let installed = HomebrewInstallationState.installed(installation)
        guard case .installed(let decodedInstallation) = installed else {
            return XCTFail("Expected installed state")
        }
        XCTAssertEqual(decodedInstallation, installation)
        XCTAssertNotEqual(installed, .notChecked)
        XCTAssertNotEqual(HomebrewInstallationState.notChecked, .checking)
        XCTAssertNotEqual(HomebrewInstallationState.commandLineToolsRequired, .notInstalled)

        let online = OnlineVersionState.available(version: "5.0.0")
        guard case .available(let version) = online else {
            return XCTFail("Expected available online version")
        }
        XCTAssertEqual(version, "5.0.0")
        guard case .unavailable(let reason) = OnlineVersionState.unavailable(reason: "Offline") else {
            return XCTFail("Expected unavailable online state")
        }
        XCTAssertEqual(reason, "Offline")
        XCTAssertNotEqual(online, .notLoaded)
    }

    func testSemanticVersionStatusDoesNotTreatAheadOrUnknownAsUpdates() {
        XCTAssertEqual(SemanticVersionStatus(current: "1.2.3", available: "2.0.0"), .behind)
        XCTAssertEqual(SemanticVersionStatus(current: "2.0.0", available: "2.0.0"), .current)

        let ahead = SemanticVersionStatus(current: "3.0.0", available: "2.0.0")
        XCTAssertEqual(ahead, .ahead)
        XCTAssertFalse(ahead.allowsUpdate)
        XCTAssertNil(CatalogCardState(
            identity: .homebrew(.init(name: "demo", kind: .formula)),
            displayName: "demo",
            description: nil,
            currentVersion: "3.0.0",
            availableVersion: "2.0.0",
            versionStatus: ahead,
            websiteURL: nil,
            progress: .idle,
            primaryAction: .update
        ))

        let unknown = SemanticVersionStatus(current: "latest", available: "2.0.0")
        XCTAssertEqual(unknown, .unknown)
        XCTAssertFalse(unknown.allowsUpdate)
        XCTAssertEqual(
            SemanticVersionStatus(current: "2.0.0-beta.2", available: "2.0.0"),
            .behind
        )
    }

    func testSemanticVersionStatusRejectsMalformedOrNonASCIIIdentifiers() {
        let invalidVersions = [
            "1.0.0+",
            "1.0.0+build..1",
            "1.0.0+build_1",
            "1.0.0+构建",
            "1.0.0-",
            "1.0.0-beta..1",
            "1.0.0-beta_1",
            "1.0.0-测试",
            "1.0.0-01",
            "v1.0.0",
            " 1.0.0",
            "1.0.0 ",
        ]

        for version in invalidVersions {
            XCTAssertEqual(
                SemanticVersionStatus(current: version, available: "2.0.0"),
                .unknown,
                version
            )
        }

        XCTAssertEqual(
            SemanticVersionStatus(current: "1.0.0-alpha.1+build.01", available: "1.0.0"),
            .behind
        )
        XCTAssertEqual(
            SemanticVersionStatus(current: "1.0.0+build.01", available: "1.0.0+other"),
            .current
        )
    }

    func testDecodesMinimalNPMRegistrySearchResult() throws {
        let data = Data(#"""
        {
          "objects": [{
            "package": {
              "name": "typescript",
              "version": "5.7.2",
              "description": "TypeScript is JavaScript with syntax for types.",
              "links": {
                "npm": "https://www.npmjs.com/package/typescript",
                "homepage": "https://www.typescriptlang.org/"
              },
              "ignored": true
            }
          }],
          "total": 1,
          "time": "ignored"
        }
        """#.utf8)

        let response = try JSONDecoder().decode(NPMRegistrySearchResponse.self, from: data)

        XCTAssertEqual(response.total, 1)
        XCTAssertEqual(response.objects.first?.package.name, "typescript")
        XCTAssertEqual(response.objects.first?.package.version, "5.7.2")
        XCTAssertEqual(
            response.objects.first?.package.links?.homepage,
            URL(string: "https://www.typescriptlang.org/")
        )
    }

    func testBatchIntentRejectsMixedScopeAndOutcomePreservesPartialResults() throws {
        let formula = BatchItem.homebrew(.init(name: "wget", kind: .formula))
        let cask = BatchItem.homebrew(.init(name: "firefox", kind: .cask))
        XCTAssertNil(BatchIntent(operation: .install, items: [formula, cask]))

        let secondFormula = BatchItem.homebrew(.init(name: "jq", kind: .formula))
        let intent = try XCTUnwrap(BatchIntent(operation: .install, items: [formula, secondFormula]))
        XCTAssertEqual(intent.scope, .homebrew(.formula))

        let result = try XCTUnwrap(BatchOutcome(
            intent: intent,
            itemOutcomes: [
                .init(item: formula, status: .succeeded, userFacingMessage: nil),
                .init(
                    item: secondFormula,
                    status: .failed,
                    userFacingMessage: "Installation failed"
                ),
            ]
        ))

        XCTAssertEqual(result.status, .partiallySucceeded)
        XCTAssertEqual(result.itemOutcomes.first?.status, .succeeded)
        XCTAssertEqual(result.succeededItemCount, 1)
    }

    func testBatchOutcomeRequiresExactlyOneOrderedOutcomePerIntentItem() throws {
        let first = BatchItem.homebrew(.init(name: "wget", kind: .formula))
        let second = BatchItem.homebrew(.init(name: "jq", kind: .formula))
        let unrelated = BatchItem.homebrew(.init(name: "tree", kind: .formula))
        let intent = try XCTUnwrap(BatchIntent(operation: .install, items: [first, second]))
        let success = BatchItemOutcome(item: first, status: .succeeded, userFacingMessage: nil)
        let failure = BatchItemOutcome(item: second, status: .failed, userFacingMessage: nil)
        let other = BatchItemOutcome(item: unrelated, status: .unknown, userFacingMessage: nil)

        XCTAssertNil(BatchOutcome(intent: intent, itemOutcomes: []))
        XCTAssertNil(BatchOutcome(intent: intent, itemOutcomes: [success]))
        XCTAssertNil(BatchOutcome(intent: intent, itemOutcomes: [success, success]))
        XCTAssertNil(BatchOutcome(intent: intent, itemOutcomes: [success, other]))
        XCTAssertNil(BatchOutcome(intent: intent, itemOutcomes: [failure, success]))
        XCTAssertNotNil(BatchOutcome(intent: intent, itemOutcomes: [success, failure]))
    }

    func testNPMBatchScopeIncludesNodeEnvironment() throws {
        let environment = NodeEnvironmentContext(
            identifier: "nvm:v22.12.0",
            nodeVersion: "v22.12.0",
            npmVersion: "10.9.0"
        )
        let item = BatchItem.npm(.init(name: "typescript", environment: environment))
        let intent = try XCTUnwrap(BatchIntent(operation: .update, items: [item]))

        XCTAssertEqual(intent.scope, .npm(environment))
    }

    func testNPMBatchRejectsItemsFromDifferentNodeEnvironments() {
        let node20 = NodeEnvironmentContext(
            identifier: "nvm:v20.18.0",
            nodeVersion: "v20.18.0",
            npmVersion: "10.8.2"
        )
        let node22 = NodeEnvironmentContext(
            identifier: "nvm:v22.12.0",
            nodeVersion: "v22.12.0",
            npmVersion: "10.9.0"
        )

        XCTAssertNil(BatchIntent(operation: .update, items: [
            .npm(.init(name: "typescript", environment: node20)),
            .npm(.init(name: "eslint", environment: node22)),
        ]))
    }

    func testActivitySummaryRoundTripsOnlySemanticFields() throws {
        let environment = NodeEnvironmentContext(
            identifier: "nvm:v22.12.0",
            nodeVersion: "v22.12.0",
            npmVersion: "10.9.0"
        )
        let summary = ActivitySummary(
            id: UUID(uuidString: "51FBB913-AC51-4C8A-A68C-7D5A11A50B15")!,
            operation: .install,
            scope: .npm(environment),
            targetDisplayNames: ["typescript"],
            date: Date(timeIntervalSince1970: 1_700_000_000),
            status: .failed,
            itemOutcomes: [
                .init(displayName: "typescript", status: .failed, reason: .providerFailure)
            ]
        )
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(ActivitySummary.self, from: data)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(decoded, summary)
        XCTAssertEqual(decoded.scope, .npm(environment))
        XCTAssertEqual(decoded.itemOutcomes.first?.reason, .providerFailure)
        XCTAssertFalse(json.contains("command"))
        XCTAssertFalse(json.contains("stdout"))
        XCTAssertFalse(json.contains("stderr"))
        XCTAssertFalse(json.contains("userFacingMessage"))
    }

    func testApplicationLanguageSupportsSystemAndEightLanguages() {
        XCTAssertEqual(ApplicationLanguage.system.rawValue, "system")
        XCTAssertEqual(ApplicationLanguage.english.rawValue, "en")
        XCTAssertEqual(ApplicationLanguage.simplifiedChinese.rawValue, "zh-Hans")
        XCTAssertEqual(ApplicationLanguage.traditionalChinese.rawValue, "zh-Hant")
        XCTAssertEqual(ApplicationLanguage.allCases.count, 9)
    }
}
