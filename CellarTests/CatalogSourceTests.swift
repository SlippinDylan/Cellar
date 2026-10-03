import Foundation
import XCTest
@testable import Cellar

final class CatalogSourceTests: XCTestCase {
    func testRegistrySearchPreservesEnvironmentAndBoundsResults() async throws {
        let transport = FakeCatalogTransport(body: Data(#"{"objects":[{"package":{"name":"@scope/tool","version":"1.2.3","links":{"homepage":"javascript:alert(1)"}}},{"package":{"name":"other","version":"2.0.0"}}],"total":2}"#.utf8))
        let http = CatalogHTTPClient(transport: transport)
        let registry = try NPMRegistryClient(registryURL: CatalogWebsites.npmRegistry, http: http)
        let environment = NodeEnvironmentContext(identifier: "v22", nodeVersion: "22.0.0", npmVersion: "11.0.0")
        let results = try await registry.search("  tool & stuff  ", environment: environment, limit: 1)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].identity, NPMPackageIdentity(name: "@scope/tool", environment: environment))
        XCTAssertEqual(results[0].registryURL, CatalogWebsites.npmRegistry)
        XCTAssertNil(results[0].websiteURL)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let components = try XCTUnwrap(URLComponents(url: requests[0].url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "text" })?.value, "tool & stuff")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "size" })?.value, "1")
        _ = try await registry.search(" \n ", environment: environment)
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    func testETagRevalidationUsesCachedBody() async throws {
        let transport = FakeCatalogTransport(body: Data("{}".utf8), etag: "\"v1\"")
        let client = CatalogHTTPClient(transport: transport)
        let first = try await client.data(from: CatalogWebsites.npmRegistry)
        await transport.setResponse(status: 304, body: Data())
        let second = try await client.data(from: CatalogWebsites.npmRegistry)
        XCTAssertEqual(first, second)
        let requests = await transport.requests
        XCTAssertEqual(requests[1].headers["If-None-Match"], "\"v1\"")
        await transport.setCacheControl("no-store")
        _ = try await client.data(from: CatalogWebsites.npmRegistry)
        await transport.setResponse(status: 200, body: Data("{}".utf8))
        _ = try await client.data(from: CatalogWebsites.npmRegistry)
        let finalRequests = await transport.requests
        XCTAssertNil(finalRequests[3].headers["If-None-Match"])
    }

    func testConcurrentNotModifiedUsesRequestCacheSnapshot() async throws {
        let transport = ConcurrentNotModifiedTransport()
        let client = CatalogHTTPClient(transport: transport)
        let url = CatalogWebsites.npmRegistry
        let original = try await client.data(from: url)
        let first = Task { try await client.data(from: url) }
        await transport.waitForPendingRequests(1)
        let second = Task { try await client.data(from: url) }
        await transport.waitForPendingRequests(2)
        let requests = await transport.requests
        XCTAssertEqual(requests.dropFirst().map { $0.headers["If-None-Match"] }, ["fixture", "fixture"])
        await transport.completeNext(cacheControl: "no-store")
        let firstResult = try await first.value
        XCTAssertEqual(firstResult, original)
        await transport.completeNext(cacheControl: nil)
        let secondResult = try await second.value
        XCTAssertEqual(secondResult, original)
    }

    func testResponseSizeStatusAndUnexpectedNotModifiedAreRejected() async throws {
        let transport = FakeCatalogTransport(body: Data(repeating: 0, count: 11))
        let client = CatalogHTTPClient(transport: transport)
        do {
            _ = try await client.data(from: CatalogWebsites.npmRegistry, maximumBytes: 10)
            XCTFail("Expected bounded response")
        } catch { XCTAssertEqual(error as? CatalogSourceError, .responseTooLarge) }
        await transport.setResponse(status: 304, body: Data())
        do {
            _ = try await client.data(from: CatalogWebsites.npmRegistry)
            XCTFail("Expected no cache rejection")
        } catch { XCTAssertEqual(error as? CatalogSourceError, .invalidResponse) }
        await transport.setResponse(status: 429, body: Data())
        do {
            _ = try await client.data(from: CatalogWebsites.npmRegistry)
            XCTFail("Expected status rejection")
        } catch { XCTAssertEqual(error as? CatalogSourceError, .httpStatus(429)) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].timeout, 20)
        XCTAssertEqual(requests[0].allowedOrigins, ["https://registry.npmjs.org"])
    }

    func testNoStoreAndMissingETagInvalidatePreviousCache() async throws {
        let transport = FakeCatalogTransport(body: Data("{}".utf8), etag: "first")
        let client = CatalogHTTPClient(transport: transport)
        _ = try await client.data(from: CatalogWebsites.npmRegistry)
        await transport.setCacheControl("no-store")
        _ = try await client.data(from: CatalogWebsites.npmRegistry)
        _ = try await client.data(from: CatalogWebsites.npmRegistry)
        let requests = await transport.requests
        XCTAssertNil(requests[2].headers["If-None-Match"])
        await transport.setCacheControl("")
        _ = try await client.data(from: CatalogWebsites.npmRegistry)
        await transport.setETag(nil)
        _ = try await client.data(from: CatalogWebsites.npmRegistry)
        _ = try await client.data(from: CatalogWebsites.npmRegistry)
        let finalRequests = await transport.requests
        XCTAssertNil(finalRequests[5].headers["If-None-Match"])
    }

    func testRegistryRejectsUnsafeOriginsAndInvalidInputs() async throws {
        for url in [URL(filePath: "/tmp/registry"), CatalogWebsites.url(host: "registry.npmjs.org", path: "/#fragment")] {
            XCTAssertThrowsError(try NPMRegistryClient(registryURL: url))
        }
        let transport = FakeCatalogTransport(body: Data(#"{"objects":[],"total":0}"#.utf8))
        let registry = try NPMRegistryClient(registryURL: CatalogWebsites.npmRegistry, http: CatalogHTTPClient(transport: transport))
        let environment = NodeEnvironmentContext(identifier: "node", nodeVersion: "22.0.0", npmVersion: "11.0.0")
        for (query, limit) in [(String(repeating: "a", count: 513), 50), ("tool", 101)] {
            do {
                _ = try await registry.search(query, environment: environment, limit: limit)
                XCTFail("Expected input rejection")
            } catch { XCTAssertEqual(error as? CatalogSourceError, .invalidQuery) }
        }
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }

    func testExplicitHTTPRegistryAndWebsitesAreAcceptedWithoutCrossOriginResponses() async throws {
        let url = try XCTUnwrap(URL(string: "http://registry.example:8080/npm/"))
        let website = try XCTUnwrap(URL(string: "http://package.example/docs"))
        let transport = FakeCatalogTransport(body: Data(#"{"objects":[{"package":{"name":"tool","version":"1.0.0","links":{"homepage":"http://package.example/docs"}}}],"total":1}"#.utf8))
        let registry = try NPMRegistryClient(registryURL: url, http: CatalogHTTPClient(transport: transport))
        let environment = NodeEnvironmentContext(identifier: "node", nodeVersion: "22.0.0", npmVersion: "11.0.0")
        let results = try await registry.search("tool", environment: environment)
        XCTAssertEqual(results.first?.registryURL, url)
        XCTAssertEqual(results.first?.websiteURL, website)
        let requests = await transport.requests
        XCTAssertEqual(requests.first?.allowedOrigins, ["http://registry.example:8080"])
        XCTAssertEqual(requests.first?.url.path, "/npm/-/v1/search")
        await transport.setResponseURL(url.appending(path: "canonical/search"))
        let redirectedResults = try await registry.search("tool", environment: environment)
        XCTAssertEqual(redirectedResults.first?.registryURL, url)
        await transport.setResponseURL(CatalogWebsites.npmRegistry)
        do { _ = try await registry.search("tool", environment: environment); XCTFail("Expected cross-origin response rejection") }
        catch { XCTAssertEqual(error as? CatalogSourceError, .invalidResponse) }
        for value in ["https://user:placeholder@registry.example/", "http://registry.example:99999/", "https://bad%20host/", "ftp://registry.example/"] {
            let unsafe = try XCTUnwrap(URL(string: value))
            XCTAssertThrowsError(try NPMRegistryClient(registryURL: unsafe))
            XCTAssertNil(CatalogWebsites.safeWebsite(unsafe))
        }
    }

    func testRedirectsRemainWithinExplicitOriginAndOfficialSourcesKeepHTTPS() async throws {
        let initial = CatalogWebsites.npmRegistry
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalCatalogURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: initial)
        let response = try XCTUnwrap(HTTPURLResponse(url: initial, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil))
        for (origin, target, expected) in [
            ("https://registry.npmjs.org", "https://registry.npmjs.org/path", true),
            ("https://registry.npmjs.org", "http://registry.npmjs.org/path", false),
            ("https://registry.npmjs.org", "https://elsewhere.example/path", false),
            ("http://registry.example:8080", "http://registry.example:8080/path", true),
            ("http://registry.example:8080", "https://registry.example:8080/path", false),
            ("https://github.com", "http://github.com/Homebrew/brew", false),
        ] {
            let delegate = CatalogRedirectPolicy(allowedOrigins: [origin])
            let request = URLRequest(url: try XCTUnwrap(URL(string: target)))
            let forwarded: URLRequest? = await withCheckedContinuation { continuation in
                delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { continuation.resume(returning: $0) }
            }
            XCTAssertEqual(forwarded != nil, expected)
        }
        XCTAssertEqual([CatalogWebsites.homebrew, CatalogWebsites.node, CatalogWebsites.npm, CatalogWebsites.npmRegistry, CatalogWebsites.nvm, CatalogWebsites.commandLineTools].map(\.scheme), Array(repeating: "https", count: 6))
    }

    func testIPv6OriginsDoNotCollideAcrossRedirectsOrResponses() async throws {
        let registry = try XCTUnwrap(URL(string: "http://[::1]:8080/"))
        let other = try XCTUnwrap(URL(string: "http://[::1:8080]/"))
        let origin = try XCTUnwrap(CatalogWebsites.origin(registry))
        XCTAssertEqual(origin, "http://[::1]:8080")
        XCTAssertEqual(CatalogWebsites.origin(other), "http://[::1:8080]")
        XCTAssertNotEqual(origin, CatalogWebsites.origin(other))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalCatalogURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: registry)
        let response = try XCTUnwrap(HTTPURLResponse(url: registry, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil))
        let policy = CatalogRedirectPolicy(allowedOrigins: [origin])
        for (target, allowed) in [(registry.appending(path: "canonical/search"), true), (other, false)] {
            let forwarded: URLRequest? = await withCheckedContinuation { continuation in
                policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: target)) { continuation.resume(returning: $0) }
            }
            XCTAssertEqual(forwarded != nil, allowed)
        }
        let transport = FakeCatalogTransport(body: Data("{}".utf8))
        let client = CatalogHTTPClient(transport: transport)
        await transport.setResponseURL(registry.appending(path: "canonical/search"))
        _ = try await client.data(from: registry)
        await transport.setResponseURL(other)
        do { _ = try await client.data(from: registry); XCTFail("Expected distinct IPv6 origin rejection") }
        catch { XCTAssertEqual(error as? CatalogSourceError, .invalidResponse) }
    }

    func testOriginsRejectDecodedHostDelimiters() throws {
        for delimiter in ["%2F", "%5C", "%3F", "%23", "%40", "%3A", "%5B", "%5D"] {
            let url = try XCTUnwrap(URL(string: "https://bad\(delimiter)host/"))
            XCTAssertNil(CatalogWebsites.origin(url), delimiter)
            XCTAssertNil(CatalogWebsites.safeWebsite(url), delimiter)
            XCTAssertThrowsError(try NPMRegistryClient(registryURL: url), delimiter)
        }
    }

    func testMalformedRegistryResultsAreRejected() async throws {
        let environment = NodeEnvironmentContext(identifier: "node", nodeVersion: "22.0.0", npmVersion: "11.0.0")
        for body in ["not json", #"{"objects":[{"package":{"name":"../bad","version":"1.0.0"}}],"total":1}"#] {
            let registry = try NPMRegistryClient(registryURL: CatalogWebsites.npmRegistry, http: CatalogHTTPClient(transport: FakeCatalogTransport(body: Data(body.utf8))))
            do {
                _ = try await registry.search("tool", environment: environment)
                XCTFail("Expected invalid data rejection")
            } catch { XCTAssertFalse(error is CancellationError) }
        }
    }

    func testRegistryPreservesLegacyPackageNames() async throws {
        let transport = FakeCatalogTransport(body: Data(#"{"objects":[{"package":{"name":"JSONStream","version":"1.3.5"}}],"total":1}"#.utf8))
        let registry = try NPMRegistryClient(registryURL: CatalogWebsites.npmRegistry, http: CatalogHTTPClient(transport: transport))
        let environment = NodeEnvironmentContext(identifier: "node", nodeVersion: "22.0.0", npmVersion: "11.0.0")
        let results = try await registry.search("JSONStream", environment: environment)
        XCTAssertEqual(results.first?.identity.name, "JSONStream")
    }

    func testReleaseRequiresExactOfficialStableAssetAndDigest() async throws {
        for (digest, expected) in [(Optional<String>.none, HomebrewSetupFailure.digestMissing), ("sha256:invalid", .digestInvalid)] {
            let body = try releaseData(digest: digest)
            let client = HomebrewReleaseClient(http: CatalogHTTPClient(transport: FakeCatalogTransport(body: body)))
            let version = try await client.latestVersion()
            XCTAssertEqual(version, "1.2.3")
            do {
                _ = try await client.installerMetadata()
                XCTFail("Expected digest rejection")
            } catch { XCTAssertEqual(error as? HomebrewSetupFailure, expected) }
        }
        for changes in [["prerelease": true], ["draft": true], ["html_url": "https://github.com/other/brew/releases/tag/1.2.3"]] as [[String: Any]] {
            let body = try releaseData(changes: changes)
            let client = HomebrewReleaseClient(http: CatalogHTTPClient(transport: FakeCatalogTransport(body: body)))
            do {
                _ = try await client.installerMetadata()
                XCTFail("Expected untrusted release rejection")
            } catch { XCTAssertEqual(error as? CatalogSourceError, .invalidResponse) }
        }
        let client = HomebrewReleaseClient(http: CatalogHTTPClient(transport: FakeCatalogTransport(body: try releaseData())))
        let metadata = try await client.installerMetadata()
        XCTAssertEqual(metadata.sha256, String(repeating: "a", count: 64))
        XCTAssertEqual(metadata.size, 7)
        for url in [CatalogWebsites.url(host: "github.com", path: "/other/brew/releases/download/1.2.3/Homebrew.pkg"), CatalogWebsites.url(host: "github.com", path: "/Homebrew/brew/releases/download/1.2.3/Other.pkg")] {
            XCTAssertThrowsError(try HomebrewInstallerMetadata(version: "1.2.3", downloadURL: url, sha256: metadata.sha256, size: 7))
        }
    }

    func testNodeOnlineFailuresPreserveOtherSources() async throws {
        let client = NodeVersionMetadataClient(http: CatalogHTTPClient(transport: NodeMetadataTransport()))
        let versions = try await client.load()
        XCTAssertEqual(versions.node, .available(version: "24.1.0"))
        XCTAssertEqual(versions.nvm, .available(version: "0.40.0"))
        guard case .unavailable = versions.npm else { return XCTFail("Expected separate npm failure") }
    }

    func testCancellationAndTimeoutAreNotRetried() async throws {
        for code in [URLError.cancelled, .timedOut] {
            let transport = ThrowingCatalogTransport(code: code)
            let client = CatalogHTTPClient(transport: transport)
            do {
                _ = try await client.data(from: CatalogWebsites.npmRegistry)
                XCTFail("Expected transport error")
            } catch { XCTAssertEqual((error as? URLError)?.code, code) }
            let count = await transport.count
            XCTAssertEqual(count, 1)
        }
        let transport = ThrowingCatalogTransport(code: .timedOut)
        let task = Task {
            try await Task.sleep(for: .seconds(10))
            return try await NodeVersionMetadataClient(http: CatalogHTTPClient(transport: transport)).load()
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testURLSessionTransportStreamsBoundedDataAndDownloadsUsingLocalProtocol() async throws {
        let transport = URLSessionCatalogTransport(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [LocalCatalogURLProtocol.self]
            return configuration
        })
        let success = request(path: "/success", maximumBytes: 3)
        let response = try await transport.data(for: success)
        XCTAssertEqual(response.body, Data("123".utf8))
        XCTAssertEqual(response.etag, "fixture")
        let root = FileManager.default.temporaryDirectory.appending(path: "cellar-download-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "fixture.pkg")
        try await transport.download(success, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("123".utf8))
        for path in ["/declared-oversize", "/chunked-oversize"] {
            do { _ = try await transport.data(for: request(path: path, maximumBytes: 2)); XCTFail("Expected bounded stream") }
            catch { XCTAssertEqual(error as? CatalogSourceError, .responseTooLarge) }
            do { try await transport.download(request(path: path, maximumBytes: 2), to: destination); XCTFail("Expected bounded download") }
            catch { XCTAssertEqual(error as? CatalogSourceError, .responseTooLarge) }
        }
        do { _ = try await transport.data(for: request(path: "/timeout", maximumBytes: 2)); XCTFail("Expected timeout") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let disallowed = CatalogHTTPRequest(url: success.url, allowedOrigins: ["https://elsewhere.invalid"], headers: [:], maximumBytes: 2, timeout: 1)
        do { _ = try await transport.data(for: disallowed); XCTFail("Expected origin rejection before IO") }
        catch { XCTAssertEqual(error as? CatalogSourceError, .invalidURL) }
    }

    func testURLSessionCancellationStopsAStalledLocalStream() async throws {
        let transport = URLSessionCatalogTransport(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [LocalCatalogURLProtocol.self]
            return configuration
        })
        let request = CatalogHTTPRequest(url: CatalogWebsites.url(host: "registry.npmjs.org", path: "/cancellation"), allowedOrigins: ["https://registry.npmjs.org"], headers: [:], maximumBytes: 100, timeout: 20)
        let task = Task { try await transport.data(for: request) }
        try await Task.sleep(for: .milliseconds(20))
        let start = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertLessThan(start.duration(to: ContinuousClock.now), .seconds(1))
    }

    private func request(path: String, maximumBytes: Int) -> CatalogHTTPRequest {
        CatalogHTTPRequest(url: CatalogWebsites.url(host: "registry.npmjs.org", path: path), allowedOrigins: ["https://registry.npmjs.org"], headers: [:], maximumBytes: maximumBytes, timeout: 1)
    }

    private func releaseData(digest: String? = "sha256:" + String(repeating: "a", count: 64), changes: [String: Any] = [:]) throws -> Data {
        var asset: [String: Any] = ["name": "Homebrew.pkg", "browser_download_url": "https://github.com/Homebrew/brew/releases/download/1.2.3/Homebrew.pkg", "size": 7]
        if let digest { asset["digest"] = digest }
        var release: [String: Any] = ["tag_name": "1.2.3", "html_url": "https://github.com/Homebrew/brew/releases/tag/1.2.3", "draft": false, "prerelease": false, "assets": [asset]]
        release.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: release)
    }
}

private final class LocalCatalogURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/timeout" { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        let headers = ["/chunked-oversize", "/cancellation"].contains(url.path) ? ["ETag": "fixture"] : ["Content-Length": "3", "ETag": "fixture"]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("123".utf8))
        if url.path == "/cancellation" { return }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

actor FakeCatalogTransport: CatalogHTTPTransport {
    private var body: Data
    private var status = 200
    private var etag: String?
    private var cacheControl: String?
    private var responseURL: URL?
    private(set) var requests: [CatalogHTTPRequest] = []

    init(body: Data, etag: String? = nil) {
        self.body = body
        self.etag = etag
    }

    func setResponse(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    func setCacheControl(_ value: String) { cacheControl = value }
    func setETag(_ value: String?) { etag = value }
    func setResponseURL(_ value: URL) { responseURL = value }

    func data(for request: CatalogHTTPRequest) async throws -> CatalogHTTPResponse {
        requests.append(request)
        return CatalogHTTPResponse(url: responseURL ?? request.url, status: status, body: body, etag: etag, cacheControl: cacheControl)
    }

    func download(_ request: CatalogHTTPRequest, to destination: URL) async throws {
        requests.append(request)
        try body.write(to: destination)
    }
}

private struct NodeMetadataTransport: CatalogHTTPTransport {
    func data(for request: CatalogHTTPRequest) async throws -> CatalogHTTPResponse {
        let body: String
        switch request.url.host {
        case "nodejs.org":
            body = #"[{"version":"v24.0.0","files":["osx-arm64-tar"]},{"version":"v24.1.0","files":["osx-arm64-tar"]},{"version":"v26.0.0-rc.1","files":["osx-arm64-tar"]},{"version":"v25.0.0","files":["linux-x64"]}]"#
        case "api.github.com":
            body = #"{"tag_name":"v0.40.0","html_url":"https://github.com/nvm-sh/nvm/releases/tag/v0.40.0","draft":false,"prerelease":false,"assets":[]}"#
        default: throw URLError(.timedOut)
        }
        return CatalogHTTPResponse(url: request.url, status: 200, body: Data(body.utf8), etag: nil)
    }
    func download(_ request: CatalogHTTPRequest, to destination: URL) async throws { throw URLError(.unsupportedURL) }
}

private actor ThrowingCatalogTransport: CatalogHTTPTransport {
    let code: URLError.Code
    private(set) var count = 0
    init(code: URLError.Code) { self.code = code }
    func data(for request: CatalogHTTPRequest) async throws -> CatalogHTTPResponse { count += 1; throw URLError(code) }
    func download(_ request: CatalogHTTPRequest, to destination: URL) async throws { throw URLError(code) }
}

private actor ConcurrentNotModifiedTransport: CatalogHTTPTransport {
    private(set) var requests: [CatalogHTTPRequest] = []
    private var pending: [(CatalogHTTPRequest, CheckedContinuation<CatalogHTTPResponse, Error>)] = []
    private var waiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

    func data(for request: CatalogHTTPRequest) async throws -> CatalogHTTPResponse {
        requests.append(request)
        if requests.count == 1 {
            return CatalogHTTPResponse(url: request.url, status: 200, body: Data("original".utf8), etag: "fixture")
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending.append((request, continuation))
            if let waiter, pending.count == waiter.count {
                self.waiter = nil
                waiter.continuation.resume()
            }
        }
    }

    func waitForPendingRequests(_ count: Int) async {
        if pending.count == count { return }
        await withCheckedContinuation { waiter = (count, $0) }
    }

    func completeNext(cacheControl: String?) {
        let (request, continuation) = pending.removeFirst()
        continuation.resume(returning: CatalogHTTPResponse(url: request.url, status: 304, body: Data(), etag: nil, cacheControl: cacheControl))
    }

    func download(_ request: CatalogHTTPRequest, to destination: URL) async throws { throw URLError(.unsupportedURL) }
}
