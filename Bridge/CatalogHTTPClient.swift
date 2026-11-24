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
        try await stream(request, destination: nil)
    }

    func download(_ request: CatalogHTTPRequest, to destination: URL) async throws {
        _ = try await stream(request, destination: destination)
    }

    private func stream(_ request: CatalogHTTPRequest, destination: URL?) async throws -> CatalogHTTPResponse {
        try Task.checkCancellation()
        let urlReq = try urlRequest(request)
        let config = makeConfiguration(request)
        let delegate = CatalogStreamDelegate(request: request, destination: destination)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: urlReq)
                delegate.start(session: session, task: task, continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }

    private func makeConfiguration(_ request: CatalogHTTPRequest) -> URLSessionConfiguration {
        let config = configuration()
        config.timeoutIntervalForRequest = request.timeout
        config.timeoutIntervalForResource = request.timeout
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        return config
    }

    private func urlRequest(_ request: CatalogHTTPRequest) throws -> URLRequest {
        guard let origin = CatalogWebsites.origin(request.url), request.allowedOrigins.contains(origin) else { throw CatalogSourceError.invalidURL }
        var result = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout)
        result.httpMethod = "GET"
        for (key, value) in request.headers { result.setValue(value, forHTTPHeaderField: key) }
        return result
    }

    static func checkedResponse(_ response: URLResponse, request: CatalogHTTPRequest) throws -> (HTTPURLResponse, URL) {
        guard let http = response as? HTTPURLResponse,
              let url = http.url,
              let origin = CatalogWebsites.origin(url), request.allowedOrigins.contains(origin)
        else { throw CatalogSourceError.invalidResponse }
        guard response.expectedContentLength <= Int64(request.maximumBytes) else { throw CatalogSourceError.responseTooLarge }
        return (http, url)
    }
}

private final class CatalogStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: CatalogHTTPRequest
    private let destination: URL?
    private let redirectPolicy: CatalogRedirectPolicy
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<CatalogHTTPResponse, Error>?
    private var response: (HTTPURLResponse, URL)?
    private var buffer = Data()
    private var fileHandle: FileHandle?
    private var receivedBytes = 0
    private var isFinished = false
    private var isCancelled = false

    init(request: CatalogHTTPRequest, destination: URL?) {
        self.request = request
        self.destination = destination
        self.redirectPolicy = CatalogRedirectPolicy(allowedOrigins: request.allowedOrigins)
    }

    func start(session: URLSession, task: URLSessionDataTask, continuation: CheckedContinuation<CatalogHTTPResponse, Error>) {
        lock.lock()
        if isCancelled {
            isFinished = true
            lock.unlock()
            session.invalidateAndCancel()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.session = session
        self.task = task
        self.continuation = continuation
        lock.unlock()
        task.resume()
    }

    func cancel() {
        let state = finishLocked {
            isCancelled = true
        }
        state.task?.cancel()
        state.session?.invalidateAndCancel()
        state.continuation?.resume(throwing: CancellationError())
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        redirectPolicy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        do {
            let checked = try URLSessionCatalogTransport.checkedResponse(response, request: request)
            var openedFile: FileHandle?
            if let destination {
                guard checked.0.statusCode == 200 else { throw CatalogSourceError.httpStatus(checked.0.statusCode) }
                guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                openedFile = try FileHandle(forWritingTo: destination)
            }
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                try? openedFile?.close()
                completionHandler(.cancel)
                return
            }
            self.response = checked
            self.fileHandle = openedFile
            lock.unlock()
            completionHandler(.allow)
        } catch {
            fail(with: error)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        guard data.count <= request.maximumBytes - receivedBytes else {
            lock.unlock()
            fail(with: CatalogSourceError.responseTooLarge)
            return
        }
        receivedBytes += data.count
        if let fileHandle {
            do {
                try fileHandle.write(contentsOf: data)
            } catch {
                lock.unlock()
                fail(with: error)
                return
            }
        } else {
            buffer.append(data)
        }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var result: Result<CatalogHTTPResponse, Error>?
        let state = finishLocked {
            if let error {
                result = .failure(isCancelled ? CancellationError() : error)
            } else if let (http, url) = response {
                let body = destination == nil ? buffer : Data()
                result = .success(CatalogHTTPResponse(
                    url: url,
                    status: http.statusCode,
                    body: body,
                    etag: http.value(forHTTPHeaderField: "ETag"),
                    cacheControl: http.value(forHTTPHeaderField: "Cache-Control")
                ))
            } else {
                result = .failure(CatalogSourceError.invalidResponse)
            }
        }
        guard let continuation = state.continuation, let result else { return }
        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let failure): continuation.resume(throwing: failure)
        }
    }

    private func fail(with error: Error) {
        let state = finishLocked {}
        state.task?.cancel()
        state.continuation?.resume(throwing: error)
    }

    private func finishLocked(_ update: () -> Void) -> (session: URLSession?, task: URLSessionDataTask?, continuation: CheckedContinuation<CatalogHTTPResponse, Error>?) {
        lock.lock()
        defer { lock.unlock() }
        update()
        guard !isFinished else { return (nil, nil, nil) }
        isFinished = true
        try? fileHandle?.close()
        fileHandle = nil
        let captured = (session, task, continuation)
        session = nil
        task = nil
        continuation = nil
        return captured
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
