import XCTest
@testable import Cellar

final class NodeManagerContractTests: XCTestCase {
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
