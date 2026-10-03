import Foundation

enum CatalogSourceError: Error, Equatable {
    case invalidURL
    case invalidQuery
    case invalidResponse
    case responseTooLarge
    case httpStatus(Int)
}

struct CatalogHTTPRequest: Sendable {
    let url: URL
    let allowedOrigins: Set<String>
    let headers: [String: String]
    let maximumBytes: Int
    let timeout: TimeInterval
}

struct CatalogHTTPResponse: Sendable {
    let url: URL
    let status: Int
    let body: Data
    let etag: String?
    let cacheControl: String?

    init(url: URL, status: Int, body: Data, etag: String?, cacheControl: String? = nil) {
        self.url = url
        self.status = status
        self.body = body
        self.etag = etag
        self.cacheControl = cacheControl
    }
}

protocol CatalogHTTPTransport: Sendable {
    func data(for request: CatalogHTTPRequest) async throws -> CatalogHTTPResponse
    func download(_ request: CatalogHTTPRequest, to destination: URL) async throws
}

struct URLSessionCatalogTransport: CatalogHTTPTransport {
    // Injected configurations allow URLProtocol fixtures without a live endpoint.
    let configuration: @Sendable () -> URLSessionConfiguration

    init(configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
        self.configuration = configuration
    }

    func data(for request: CatalogHTTPRequest) async throws -> CatalogHTTPResponse {
        try Task.checkCancellation()
        let session = makeSession(request)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            let (bytes, response) = try await session.bytes(for: urlRequest(request))
            let (http, responseURL) = try checkedResponse(response, request: request)
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < request.maximumBytes else { throw CatalogSourceError.responseTooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            return CatalogHTTPResponse(url: responseURL, status: http.statusCode, body: data, etag: http.value(forHTTPHeaderField: "ETag"), cacheControl: http.value(forHTTPHeaderField: "Cache-Control"))
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func download(_ request: CatalogHTTPRequest, to destination: URL) async throws {
        try Task.checkCancellation()
        let session = makeSession(request)
        defer { session.invalidateAndCancel() }
        try await withTaskCancellationHandler {
            let (bytes, response) = try await session.bytes(for: urlRequest(request))
            let (http, _) = try checkedResponse(response, request: request)
            guard http.statusCode == 200 else { throw CatalogSourceError.httpStatus(http.statusCode) }
            guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let file = try FileHandle(forWritingTo: destination)
            defer { try? file.close() }
            var count = 0
            var chunk = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard count < request.maximumBytes else { throw CatalogSourceError.responseTooLarge }
                count += 1
                chunk.append(byte)
                if chunk.count == 65_536 {
                    try file.write(contentsOf: chunk)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            try Task.checkCancellation()
            try file.write(contentsOf: chunk)
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    private func makeSession(_ request: CatalogHTTPRequest) -> URLSession {
        let config = configuration()
        config.timeoutIntervalForRequest = request.timeout
        config.timeoutIntervalForResource = request.timeout
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        return URLSession(configuration: config, delegate: CatalogRedirectPolicy(allowedOrigins: request.allowedOrigins), delegateQueue: nil)
    }

    private func urlRequest(_ request: CatalogHTTPRequest) throws -> URLRequest {
        guard let origin = CatalogWebsites.origin(request.url), request.allowedOrigins.contains(origin) else { throw CatalogSourceError.invalidURL }
        var result = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout)
        result.httpMethod = "GET"
        for (key, value) in request.headers { result.setValue(value, forHTTPHeaderField: key) }
        return result
    }

    private func checkedResponse(_ response: URLResponse, request: CatalogHTTPRequest) throws -> (HTTPURLResponse, URL) {
        guard let http = response as? HTTPURLResponse,
              let url = http.url,
              let origin = CatalogWebsites.origin(url), request.allowedOrigins.contains(origin)
        else { throw CatalogSourceError.invalidResponse }
        guard response.expectedContentLength <= Int64(request.maximumBytes) else { throw CatalogSourceError.responseTooLarge }
        return (http, url)
    }
}

final class CatalogRedirectPolicy: NSObject, URLSessionTaskDelegate {
    let allowedOrigins: Set<String>
    init(allowedOrigins: Set<String>) { self.allowedOrigins = allowedOrigins }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, let origin = CatalogWebsites.origin(url), allowedOrigins.contains(origin) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

actor CatalogHTTPClient {
    private let transport: any CatalogHTTPTransport
    private var cache: [URL: CatalogHTTPResponse] = [:]
    private var cacheOrder: [URL] = []
    private static let cacheByteLimit = 8 * 1_024 * 1_024

    init(transport: any CatalogHTTPTransport = URLSessionCatalogTransport()) { self.transport = transport }

    func data(from url: URL, maximumBytes: Int = 2 * 1_024 * 1_024) async throws -> Data {
        try Task.checkCancellation()
        guard let origin = CatalogWebsites.origin(url) else { throw CatalogSourceError.invalidURL }
        var headers = ["Accept": "application/json", "User-Agent": "Cellar"]
        if url.host == "api.github.com" { headers["X-GitHub-Api-Version"] = "2022-11-28" }
        let cachedResponse = cache[url]
        if let etag = cachedResponse?.etag { headers["If-None-Match"] = etag }
        let response = try await transport.data(for: CatalogHTTPRequest(url: url, allowedOrigins: [origin], headers: headers, maximumBytes: maximumBytes, timeout: 20))
        try Task.checkCancellation()
        guard CatalogWebsites.origin(response.url) == origin else { throw CatalogSourceError.invalidResponse }
        guard response.body.count <= maximumBytes else { throw CatalogSourceError.responseTooLarge }
        if response.status == 304 {
            guard let cached = cachedResponse, cached.body.count <= maximumBytes else { throw CatalogSourceError.invalidResponse }
            if response.cacheControl?.lowercased().contains("no-store") == true {
                cache[url] = nil
                cacheOrder.removeAll { $0 == url }
            }
            return cached.body
        }
        guard response.status == 200 else { throw CatalogSourceError.httpStatus(response.status) }
        cache[url] = nil
        cacheOrder.removeAll { $0 == url }
        if response.cacheControl?.lowercased().contains("no-store") != true,
           let etag = response.etag, !etag.isEmpty, etag.utf8.count <= 1_024,
           !etag.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            while cacheOrder.count >= 16 || cache.values.reduce(0, { $0 + $1.body.count }) + response.body.count > Self.cacheByteLimit {
                guard !cacheOrder.isEmpty else { break }
                cache[cacheOrder.removeFirst()] = nil
            }
            if response.body.count <= Self.cacheByteLimit {
                cache[url] = response
                cacheOrder.append(url)
            }
        }
        return response.body
    }
}
