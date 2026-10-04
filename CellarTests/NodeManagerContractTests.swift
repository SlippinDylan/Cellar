import XCTest
@testable import Cellar

final class NodeManagerContractTests: XCTestCase {
    func testDecodesActualUninstallResidueWarningResponse() throws {
        let result = try JSONDecoder().decode(ManagerEnvelope<NodeOperationResult>.self, from: Data(nodeUninstallResidueResponse.utf8))
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.data?.action, "uninstall")
        XCTAssertEqual(result.data?.exitCode, 0)
        XCTAssertEqual(result.data?.status, "warn")
        XCTAssertEqual(result.data?.detail, "residue-detected")
        XCTAssertEqual(result.data?.residues?.directories, ["/private/fake/lib/node_modules/one"])
        XCTAssertEqual(result.data?.residues?.bins, ["/private/fake/bin/one"])
        XCTAssertEqual(result.data?.batchItemStatus, .partiallySucceeded)
    }

    func testUninstallWarningRequiresSuccessfulRemovalAndKnownResidueDetail() throws {
        for (original, changed) in [("\"exitCode\":0", "\"exitCode\":7"),
                                    ("\"detail\":\"residue-detected\"", "\"detail\":\"still-installed\""),
                                    ("\"action\":\"uninstall\"", "\"action\":\"update-latest\"")] {
            let json = nodeUninstallResidueResponse.replacingOccurrences(of: original, with: changed)
            let result = try JSONDecoder().decode(ManagerEnvelope<NodeOperationResult>.self, from: Data(json.utf8))
            XCTAssertEqual(result.data?.batchItemStatus, .failed)
        }
    }
    func testDecodesSummaryEnvelope() throws {
        let json = #"{"ok":true,"schemaVersion":1,"command":"summary","data":{"nodePath":"/opt/node","npmPath":"/opt/npm","nodeVersion":"v24.0.0","npmVersion":"11.0.0","nvmLoaded":false,"globalPrefix":"/opt","globalRoot":"/opt/lib/node_modules","registry":"https://registry.npmjs.org/"}}"#

        let envelope = try JSONDecoder().decode(
            ManagerEnvelope<NodeSummary>.self,
            from: Data(json.utf8)
        )

        XCTAssertTrue(envelope.ok)
        XCTAssertEqual(envelope.schemaVersion, 1)
        XCTAssertEqual(envelope.data?.nodeVersion, "v24.0.0")
        XCTAssertNil(envelope.error)
    }

    func testDecodesPackageInventoryWithMissingDependencies() throws {
        let json = #"{"ok":true,"schemaVersion":1,"command":"packages","data":{"name":"lib"}}"#
        let envelope = try JSONDecoder().decode(
            ManagerEnvelope<NodePackageInventory>.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(envelope.data?.dependencies?.count, nil)
    }
}

let nodeUninstallResidueResponse = #"{"ok":true,"schemaVersion":1,"command":"execute","data":{"operationId":"uninstall-one","action":"uninstall","subject":"one","packageName":"one","installedVersion":"1.0.0","exitCode":0,"status":"warn","detail":"residue-detected","logFile":"/private/fake/log","residueCleanupPerformed":false,"cleanedResidues":0,"failedResidueCleanups":0,"residues":{"directories":["/private/fake/lib/node_modules/one"],"bins":["/private/fake/bin/one"]}}}"#
