import Security
import XCTest
@testable import Cellar

final class CaskAuthorizationTests: XCTestCase {
    func testStagedAuthorizationRunsOnlyMatchingCodeAndAlwaysRemovesStaging() async throws {
        let files = FileManager.default
        let fixture = files.temporaryDirectory.appending(path: "CellarAuthorizationTests-\(UUID().uuidString)")
        let app = fixture.appending(path: "Source App's.app")
        let executable = app.appending(path: "Contents/MacOS/Cellar")
        try files.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? files.removeItem(at: fixture) }
        try files.copyItem(at: URL(filePath: "/bin/echo"), to: executable)
        let info = ["CFBundleIdentifier": "com.cellar.tests.authorization", "CFBundleExecutable": "Cellar",
                    "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))

        let runner = ProcessRunner()
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": fixture.path]
        func request(_ path: String, _ arguments: [String]) -> ProcessRequest {
            .init(executableURL: URL(filePath: path), arguments: arguments, environment: environment,
                  currentDirectoryURL: fixture, timeout: .seconds(20))
        }
        // Cellar ships one architecture; a universal fixture would need a different CDHash per slice.
        let thinned = try await runner.run(request("/usr/bin/lipo", ["/bin/echo", "-thin", "arm64e", "-output", executable.path]))
        XCTAssertEqual(thinned.terminationStatus, 0, thinned.errorText)
        let signed = try await runner.run(request("/usr/bin/codesign", ["--force", "--sign", "-", app.path]))
        XCTAssertEqual(signed.terminationStatus, 0, signed.errorText)
        let valid = try await runner.run(request("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]))
        XCTAssertEqual(valid.terminationStatus, 0, valid.errorText)

        // Inspect the production command without ever executing its authorization request.
        let source = CaskRemovalAuthorizer.authorizationScript
        let authorization = try XCTUnwrap(source.range(of: "do shell script commandText with administrator privileges"))
        let inspection = source.replacingCharacters(in: authorization, with: "return commandText")
        guard !inspection.contains("administrator privileges") else {
            return XCTFail("The inspection script must never request authorization")
        }
        let payload = "harmless-fixture-payload"
        func executeStagedCopy(requirement: String, name: String) async throws -> ProcessResult {
            let inspected = try await runner.run(request("/usr/bin/osascript", ["-e", inspection, app.path,
                requirement, CaskRemovalPrivilegedMode.flag, payload]))
            XCTAssertEqual(inspected.terminationStatus, 0, inspected.errorText)
            let template = "/private/var/tmp/CellarAuthorized.XXXXXXXX"
            guard inspected.outputText.components(separatedBy: template).count == 2 else {
                XCTFail("Expected exactly one staging template before confining the command to the fixture")
                throw CocoaError(.fileReadCorruptFile)
            }
            let script = fixture.appending(path: name)
            try Data(inspected.outputText.replacingOccurrences(of: template,
                with: fixture.appending(path: "CellarAuthorized.XXXXXXXX").path).utf8).write(to: script)
            let syntax = try await runner.run(request("/bin/sh", ["-n", script.path]))
            XCTAssertEqual(syntax.terminationStatus, 0, syntax.errorText)
            let result = try await runner.run(request("/bin/sh", [script.path]))
            XCTAssertTrue(files.fileExists(atPath: executable.path))
            let remaining = try files.contentsOfDirectory(atPath: fixture.path)
            XCTAssertFalse(remaining.contains { $0.hasPrefix("CellarAuthorized.") }, "The exit trap must remove staging")
            return result
        }

        let rejected = try await executeStagedCopy(requirement: "cdhash H\"0000000000000000000000000000000000000000\"",
                                                  name: "reject-staged-copy.sh")
        XCTAssertNotEqual(rejected.terminationStatus, 0)
        XCTAssertTrue(rejected.errorText.contains("code failed to satisfy specified code requirement"), rejected.errorText)
        XCTAssertTrue(rejected.outputText.isEmpty, rejected.outputText)
        XCTAssertFalse(rejected.outputText.contains(payload))

        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(app as CFURL, [], &code), errSecSuccess)
        let signedCode = try XCTUnwrap(code)
        var signingInformation: CFDictionary?
        XCTAssertEqual(SecCodeCopySigningInformation(signedCode, [], &signingInformation), errSecSuccess)
        let values = try XCTUnwrap(signingInformation as? [String: Any])
        let hash = try XCTUnwrap(values[kSecCodeInfoUnique as String] as? Data)
        XCTAssertEqual(hash.count, 20)
        let requirement = "cdhash H\"\(hash.map { String(format: "%02x", $0) }.joined())\""
        let accepted = try await executeStagedCopy(requirement: requirement, name: "accept-staged-copy.sh")
        XCTAssertEqual(accepted.terminationStatus, 0, accepted.errorText)
        XCTAssertEqual(accepted.outputText, "\(CaskRemovalPrivilegedMode.flag) \(payload)\n")
    }
}
