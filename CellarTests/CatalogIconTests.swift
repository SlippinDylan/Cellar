import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers
import XCTest
@testable import Cellar

final class CatalogIconTests: XCTestCase {
    func testOnlyExplicitOfficialCasksResolveByToken() throws {
        let expected = CatalogIcon.remote(try XCTUnwrap(URL(string: "https://cdn.jsdelivr.net/gh/alielsokary/CaskFlow@icons/firefox.png")))
        XCTAssertEqual(CatalogIcon.homebrew(package("firefox", tap: "homebrew/cask")), expected)
        XCTAssertEqual(CatalogIcon.homebrew(package("homebrew/cask/firefox", tap: "homebrew/cask")), expected)
        for (name, tap) in [("firefox", "vendor/tools"), ("vendor/tools/firefox", "vendor/tools"),
                            ("vendor/tools/firefox", "homebrew/cask"), ("../firefox", "homebrew/cask"),
                            ("firefox?other", "homebrew/cask")] {
            XCTAssertEqual(CatalogIcon.homebrew(package(name, tap: tap)), .placeholder)
        }
        XCTAssertEqual(CatalogIcon.homebrew(package("firefox", tap: nil)), .placeholder)
        XCTAssertEqual(CatalogIcon.homebrew(package("firefox", tap: "homebrew/cask", kind: .formula)), .placeholder)
    }

    func testLibraryAndDiscoverUseTheSameIconWithoutChangingIdentity() throws {
        let package = package("firefox", tap: "homebrew/cask", installed: ["1.0"])
        let card = DiscoverResult.homebrew(package).card(homebrew: nil, node: nil, activeIntent: nil,
                                                       running: nil, canInstall: true)
        XCTAssertEqual(card.icon, CatalogIcon.homebrew(package))
        XCTAssertEqual(card.identity, .homebrew(package.identity))
        XCTAssertEqual(card.primaryAction, .uninstall)
        let snapshot = HomebrewSnapshot(executablePath: "/fixture/brew", version: "5.0",
            configuration: .init(prefix: "", repository: "", cache: "", cellar: "", values: [:]),
            packages: [package], outdatedPackages: [], taps: [], sectionErrors: [:], controlledPath: "",
            commandLineToolsAvailable: true)
        let library = try XCTUnwrap(LibraryCatalog.cards(homebrew: snapshot, node: nil,
            homebrewUpdates: .available, nodeUpdates: .notLoaded).first)
        XCTAssertEqual(library.icon, card.icon)
        XCTAssertEqual(library.identity, card.identity)
        XCTAssertEqual(library.primaryAction, .uninstall)
    }

    func testInstalledCaskResolvesAllowedLocalAppCandidatesAndRejectsUnsafePaths() throws {
        let home = URL(filePath: "/Users/fixture-user")
        let validArtifacts = [
            HomebrewCaskArtifact(kind: "app", values: ["Alcove.app"], category: .installed,
                                 application: .init(source: "Subdir/Alcove.app", target: nil)),
            HomebrewCaskArtifact(kind: "app", values: ["~/Applications/Custom.app"], category: .installed,
                                 application: .init(source: "Custom.app", target: "~/Applications/Custom.app")),
            HomebrewCaskArtifact(kind: "app", values: ["/etc/passwd"], category: .installed,
                                 application: .init(source: "/etc/passwd", target: "/etc/passwd")),
            HomebrewCaskArtifact(kind: "app", values: ["/Applications/../tmp/Evil.app"], category: .installed,
                                 application: .init(source: "Evil.app", target: "/Applications/../tmp/Evil.app")),
            HomebrewCaskArtifact(kind: "app", values: ["/Applications/NotAnApp"], category: .installed,
                                 application: .init(source: "NotAnApp", target: "/Applications/NotAnApp")),
        ]
        let installedCask = HomebrewPackage(
            identity: .init(name: "alcove", kind: .cask), displayName: "Alcove", description: nil, homepage: nil,
            installedVersions: ["1.0"], currentVersion: "1.0", tap: "vendor/tap", dependencies: [],
            pinned: false, deprecated: false, disabled: false, artifacts: validArtifacts
        )
        let resolved = CatalogIcon.homebrew(installedCask, homeDirectory: home)
        XCTAssertEqual(resolved, .localApp(
            candidates: [
                "/Applications/Alcove.app",
                "/Users/fixture-user/Applications/Alcove.app",
                "/Users/fixture-user/Applications/Custom.app",
            ],
            fallback: nil
        ))
    }

    func testSuccessIsCachedAndSharedByStoreInstances() async throws {
        let png = try pngData()
        let transport = IconTransport(body: png)
        let cache = memoryCache()
        let store = CatalogIconStore(cache: cache, transport: transport)
        let first = await store.data(for: icon())
        let second = await CatalogIconStore(cache: cache, transport: transport).data(for: icon())
        XCTAssertEqual(first, png)
        XCTAssertEqual(second, png)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.allowedOrigins, ["https://cdn.jsdelivr.net"])
        XCTAssertEqual(requests.first?.maximumBytes, 1_024 * 1_024)
        XCTAssertEqual(requests.first?.timeout, 10)
    }

    func testCacheExpiresAfterSevenDays() async throws {
        let transport = IconTransport(body: try pngData())
        let cache = memoryCache()
        let date = Date(timeIntervalSince1970: 1_000_000)
        _ = await CatalogIconStore(cache: cache, transport: transport, now: { date }).data(for: icon())
        _ = await CatalogIconStore(cache: cache, transport: transport, now: { date.addingTimeInterval(8 * 86_400) }).data(for: icon())
        let count = await transport.requests.count
        XCTAssertEqual(count, 2)
    }

    func testConcurrentCardsShareRequestsAndLimitTransportConcurrency() async throws {
        let transport = IconTransport(body: try pngData())
        let store = CatalogIconStore(cache: memoryCache(), transport: transport)
        let icons = try (0..<12).map { index in
            CatalogIcon.remote(try XCTUnwrap(URL(string: "https://cdn.jsdelivr.net/gh/alielsokary/CaskFlow@icons/fixture-\(index).png")))
        }
        let results = await withTaskGroup(of: Data?.self, returning: [Data?].self) { group in
            for icon in icons + icons {
                group.addTask { await store.data(for: icon) }
            }
            var results: [Data?] = []
            for await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(results.count, 24)
        XCTAssertTrue(results.allSatisfy { $0 != nil })
        let count = await transport.requests.count
        let peak = await transport.peakRequests
        XCTAssertEqual(count, 12)
        XCTAssertLessThanOrEqual(peak, 4)
    }

    func testTransportTimeoutAndCancellationReturnPlaceholder() async {
        for code in [URLError.timedOut, .cancelled] {
            let transport = FailingIconTransport(code: code)
            let data = await CatalogIconStore(cache: memoryCache(), transport: transport).data(for: icon())
            XCTAssertNil(data)
        }
    }

    func testCancelledQueuedCardReturnsWithoutStartingDownloadOrCachingFailure() async throws {
        let transport = GatedIconTransport(body: try pngData())
        let store = CatalogIconStore(cache: memoryCache(), transport: transport)
        let active = try await occupyDownloadSlots(store: store, transport: transport)
        let queuedIcon = icon()
        let cancelled = expectation(description: "Cancelled queued card returns before active downloads finish")
        let queued = Task {
            let data = await store.data(for: queuedIcon)
            cancelled.fulfill()
            return data
        }
        await waitForSubscribers(5, in: store)
        queued.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        await transport.unblock()
        for task in active { _ = await task.value }
        let result = await queued.value
        XCTAssertNil(result)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 4, "A cancelled queued card must not reach the transport")
        let retry = await store.data(for: queuedIcon)
        XCTAssertNotNil(retry, "Cancelling a subscription must not create a negative cache entry")
    }

    func testQueuedSharedRequestSurvivesUntilLastSubscriberCancels() async throws {
        for cancelRemaining in [false, true] {
            let png = try pngData()
            let transport = GatedIconTransport(body: png)
            let store = CatalogIconStore(cache: memoryCache(), transport: transport)
            let active = try await occupyDownloadSlots(store: store, transport: transport)
            let requestedIcon = icon()
            let firstReturned = expectation(description: "First shared subscriber cancelled")
            let secondReturned = expectation(description: "Second shared subscriber finished")
            let first = Task {
                let data = await store.data(for: requestedIcon)
                firstReturned.fulfill()
                return data
            }
            let second = Task {
                let data = await store.data(for: requestedIcon)
                secondReturned.fulfill()
                return data
            }
            await waitForSubscribers(6, in: store)
            first.cancel()
            await fulfillment(of: [firstReturned], timeout: 2)
            await waitForSubscribers(5, in: store)
            if cancelRemaining {
                second.cancel()
                await fulfillment(of: [secondReturned], timeout: 2)
                await waitForSubscribers(4, in: store)
            }
            await transport.unblock()
            for task in active { _ = await task.value }
            let firstResult = await first.value
            let secondResult = await second.value
            XCTAssertNil(firstResult)
            XCTAssertEqual(secondResult, cancelRemaining ? nil : png)
            let count = await transport.requests.count
            XCTAssertEqual(count, cancelRemaining ? 4 : 5)
            if !cancelRemaining { await fulfillment(of: [secondReturned], timeout: 2) }
        }
    }

    func testCancelledActiveSubscriberDoesNotPreventRejoiningOrCachingDownload() async throws {
        let png = try pngData()
        let transport = GatedIconTransport(body: png)
        let store = CatalogIconStore(cache: memoryCache(), transport: transport)
        let requestedIcon = icon()
        let cancelled = expectation(description: "Active subscriber returns before network completes")
        let first = Task {
            let data = await store.data(for: requestedIcon)
            cancelled.fulfill()
            return data
        }
        await transport.waitForRequests(1)
        first.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        await waitForSubscribers(0, in: store)
        let second = Task { await store.data(for: requestedIcon) }
        await waitForSubscribers(1, in: store)
        await transport.unblock()
        let firstResult = await first.value
        let secondResult = await second.value
        let cached = await store.data(for: requestedIcon)
        XCTAssertNil(firstResult)
        XCTAssertEqual(secondResult, png)
        XCTAssertEqual(cached, png)
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testFailuresUsePlaceholderAndRetryOnlyAfterFailureTTL() async throws {
        let time = Mutex(Date(timeIntervalSince1970: 1_000_000))
        let transport = IconTransport(body: Data(), status: 404)
        let store = CatalogIconStore(cache: memoryCache(), transport: transport, now: { time.withLock { $0 } })
        let first = await store.data(for: icon())
        let second = await store.data(for: icon())
        XCTAssertNil(first)
        XCTAssertNil(second)
        var count = await transport.requests.count
        XCTAssertEqual(count, 1)
        time.withLock { $0 = $0.addingTimeInterval(301) }
        _ = await store.data(for: icon())
        count = await transport.requests.count
        XCTAssertEqual(count, 2)
    }

    func testInvalidImagesAndOversizedResponsesAreNotCached() async throws {
        for body in [Data("<html>not an icon</html>".utf8), Data(repeating: 0, count: 1_024 * 1_024 + 1)] {
            let transport = IconTransport(body: body)
            let cache = memoryCache()
            let data = await CatalogIconStore(cache: cache, transport: transport).data(for: icon())
            XCTAssertNil(data)
            XCTAssertEqual(cache.currentMemoryUsage, 0)
        }
    }

    func testPlaceholderAndCancelledCardsDoNotRequestNetwork() async {
        let transport = IconTransport(body: Data())
        let store = CatalogIconStore(cache: memoryCache(), transport: transport)
        let placeholder = await store.data(for: .placeholder)
        XCTAssertNil(placeholder)
        let requestedIcon = icon()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.data(for: requestedIcon)
        }
        let cancelled = await task.value
        XCTAssertNil(cancelled)
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }

    private func memoryCache() -> URLCache {
        URLCache(memoryCapacity: 2 * 1_024 * 1_024, diskCapacity: 0, directory: nil)
    }

    private func occupyDownloadSlots(store: CatalogIconStore, transport: GatedIconTransport) async throws -> [Task<Data?, Never>] {
        let tasks = try (0..<4).map { index in
            let icon = CatalogIcon.remote(try XCTUnwrap(URL(string: "https://cdn.jsdelivr.net/gh/alielsokary/CaskFlow@icons/active-\(index).png")))
            return Task { await store.data(for: icon) }
        }
        await transport.waitForRequests(4)
        return tasks
    }

    private func waitForSubscribers(_ count: Int, in store: CatalogIconStore) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await store.subscriberCount != count, ContinuousClock.now < deadline { await Task.yield() }
        let actual = await store.subscriberCount
        XCTAssertEqual(actual, count)
    }

    private func icon() -> CatalogIcon {
        CatalogIcon.homebrew(package("firefox", tap: "homebrew/cask"))
    }

    private func package(_ name: String, tap: String?, kind: HomebrewPackageKind = .cask,
                         installed: [String] = []) -> HomebrewPackage {
        HomebrewPackage(identity: .init(name: name, kind: kind), displayName: "Unrelated display name",
                        description: nil, homepage: nil, installedVersions: installed, currentVersion: "1.0",
                        tap: tap, dependencies: [], pinned: false, deprecated: false, disabled: false, artifacts: [])
    }

    private func pngData() throws -> Data {
        let data = NSMutableData()
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                             bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private actor IconTransport: CatalogHTTPTransport {
    let body: Data
    let status: Int
    var requests: [CatalogHTTPRequest] = []
    var activeRequests = 0
    var peakRequests = 0

    init(body: Data, status: Int = 200) {
        self.body = body
        self.status = status
    }

    func data(for request: CatalogHTTPRequest) async throws -> CatalogHTTPResponse {
        requests.append(request)
        activeRequests += 1
        peakRequests = max(peakRequests, activeRequests)
        await Task.yield()
        activeRequests -= 1
        return CatalogHTTPResponse(url: request.url, status: status, body: body, etag: nil)
    }

    func download(_ request: CatalogHTTPRequest, to destination: URL) async throws {
        throw URLError(.unsupportedURL)
    }
}

private struct FailingIconTransport: CatalogHTTPTransport {
    let code: URLError.Code

    func data(for request: CatalogHTTPRequest) async throws -> CatalogHTTPResponse { throw URLError(code) }
    func download(_ request: CatalogHTTPRequest, to destination: URL) async throws { throw URLError(code) }
}

private actor GatedIconTransport: CatalogHTTPTransport {
    let body: Data
    var requests: [CatalogHTTPRequest] = []
    private var blocked = true
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observer: (count: Int, continuation: CheckedContinuation<Void, Never>)?

    init(body: Data) { self.body = body }

    func data(for request: CatalogHTTPRequest) async throws -> CatalogHTTPResponse {
        requests.append(request)
        if let observer, requests.count >= observer.count {
            self.observer = nil
            observer.continuation.resume()
        }
        if blocked { await withCheckedContinuation { waiters.append($0) } }
        return CatalogHTTPResponse(url: request.url, status: 200, body: body, etag: nil)
    }

    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { observer = (count, $0) }
    }

    func unblock() {
        blocked = false
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    func download(_ request: CatalogHTTPRequest, to destination: URL) async throws {
        throw URLError(.unsupportedURL)
    }
}
