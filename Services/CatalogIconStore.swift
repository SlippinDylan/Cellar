import Foundation
import ImageIO
import UniformTypeIdentifiers

actor CatalogIconStore {
    static let shared = CatalogIconStore(cache: URLCache(
        memoryCapacity: 8 * 1_024 * 1_024,
        diskCapacity: 64 * 1_024 * 1_024,
        directory: URL.cachesDirectory.appending(path: "com.dylanwang.Cellar/CatalogIcons")
    ))

    private let cache: URLCache
    private let transport: any CatalogHTTPTransport
    private let now: @Sendable () -> Date
    private final class Request {
        let url: URL
        var subscribers: [UUID: CheckedContinuation<Data?, Never>] = [:]
        var hasStarted = false

        init(url: URL) { self.url = url }
    }

    private var pending: [URL: Request] = [:]
    private var failures: [URL: Date] = [:]
    private var activeRequests = 0
    private var queue: [Request] = []

    var subscriberCount: Int { pending.values.reduce(0) { $0 + $1.subscribers.count } }

    init(cache: URLCache, transport: any CatalogHTTPTransport = URLSessionCatalogTransport(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.cache = cache
        self.transport = transport
        self.now = now
    }

    func data(for icon: CatalogIcon) async -> Data? {
        guard case .remote(let url) = icon, !Task.isCancelled else { return nil }
        let request = URLRequest(url: url)
        if let cached = cache.cachedResponse(for: request),
           let stored = cached.userInfo?["storedAt"] as? Date,
           now().timeIntervalSince(stored) < 7 * 24 * 60 * 60 {
            return cached.data
        }
        if let failed = failures[url], now().timeIntervalSince(failed) < 5 * 60 { return nil }
        let subscriberID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                if let request = pending[url] {
                    request.subscribers[subscriberID] = continuation
                } else {
                    let request = Request(url: url)
                    request.subscribers[subscriberID] = continuation
                    pending[url] = request
                    queue.append(request)
                    startQueuedRequests()
                }
            }
        } onCancel: {
            Task { await self.cancelSubscriber(subscriberID, for: url) }
        }
    }

    private func cancelSubscriber(_ id: UUID, for url: URL) {
        // Completion may already have removed this subscriber before cancellation arrives.
        guard let request = pending[url], let continuation = request.subscribers.removeValue(forKey: id) else { return }
        continuation.resume(returning: nil)
        if request.subscribers.isEmpty && !request.hasStarted {
            queue.removeAll { $0 === request }
            pending[url] = nil
        }
    }

    private func startQueuedRequests() {
        while activeRequests < 4 && !queue.isEmpty {
            let request = queue.removeFirst()
            request.hasStarted = true
            activeRequests += 1
            // Started downloads can finish and populate the cache after their cards disappear.
            Task {
                do {
                    let data = try await fetch(request.url)
                    complete(request, result: .success(data))
                } catch {
                    complete(request, result: .failure(error))
                }
            }
        }
    }

    private func complete(_ request: Request, result: Result<Data, Error>) {
        let url = request.url
        let data: Data?
        switch result {
        case .success(let body):
            failures[url] = nil
            let response = URLResponse(url: url, mimeType: "image/png", expectedContentLength: body.count, textEncodingName: nil)
            cache.storeCachedResponse(CachedURLResponse(response: response, data: body,
                                                       userInfo: ["storedAt": now()], storagePolicy: .allowed), for: URLRequest(url: url))
            data = body
        case .failure:
            // An icon is optional presentation data; a failed request must not fail a catalog or task.
            failures = failures.filter { now().timeIntervalSince($0.value) < 5 * 60 }
            if failures.count >= 512 { failures.removeAll(keepingCapacity: true) }
            failures[url] = now()
            data = nil
        }
        pending[url] = nil
        activeRequests -= 1
        for continuation in request.subscribers.values { continuation.resume(returning: data) }
        startQueuedRequests()
    }

    private func fetch(_ url: URL) async throws -> Data {
        guard url.scheme == "https", url.host == "cdn.jsdelivr.net",
              url.path.hasPrefix("/gh/alielsokary/CaskFlow@icons/")
        else { throw CatalogSourceError.invalidURL }
        let response = try await transport.data(for: CatalogHTTPRequest(
            url: url, allowedOrigins: ["https://cdn.jsdelivr.net"], headers: ["Accept": "image/png"],
            maximumBytes: 1_024 * 1_024, timeout: 10
        ))
        guard response.url == url, response.status == 200,
              response.body.count <= 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(response.body as CFData, nil),
              CGImageSourceGetType(source) == UTType.png.identifier as CFString,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...1_024).contains(width), (1...1_024).contains(height),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        else { throw CatalogSourceError.invalidResponse }
        return response.body
    }
}
