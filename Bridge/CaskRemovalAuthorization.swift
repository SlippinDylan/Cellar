import Darwin
import Foundation
import Security

enum CaskRemovalAuthorizationError: LocalizedError {
    case failed(status: Int32, detail: String)
    case timedOut(detail: String)

    var errorDescription: String? {
        switch self {
        case .failed(_, let detail), .timedOut(let detail): detail
        }
    }
}

// A one-shot mode of the signed executable, not a persistent privileged service.
struct CaskRemovalAuthorizationRequest: Codable {
    let userID: uid_t
    let home: String
    let ownerPID: pid_t
    let expiresAt: Date
    let lease: String
    let entries: [CaskRemovalEntry]
    let removal: CaskRemovalPlan

    func validate() throws {
        guard let user = getpwuid(userID) else { throw CocoaError(.fileWriteNoPermission) }
        try validate(ownerHome: CaskRemovalFileSystem.physicalURL(URL(filePath: String(cString: user.pointee.pw_dir))).path, now: Date())
    }

    func validate(ownerHome: String, now: Date) throws {
        guard userID != 0, ownerHome == home, home != "/", CaskRemovalFileSystem.isNormalized(home),
              entries.count <= 1_000, !entries.isEmpty,
              expiresAt > now, expiresAt.timeIntervalSince(now) <= 300, ownerPID > 1,
              entries.allSatisfy({ $0.disposition == .remove && Self.allows($0.path, home: home) && removal.entries.contains($0) }) else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    static func allows(_ path: String, home: String) -> Bool {
        guard CaskRemovalFileSystem.isNormalized(path) else { return false }
        let homeURL = URL(filePath: home)
        if let related = CaskRemovalPathPolicy.relatedPath(path, home: homeURL) { return !related.isSharedContainer }
        return path.hasPrefix(homeURL.appending(path: "Library/Caches/Homebrew").path + "/")
    }
}

struct CaskRemovalAuthorizer: Sendable {
    let runner: ProcessRunner

    func remove(_ entries: [CaskRemovalEntry], home: URL, removal: CaskRemovalPlan,
                applicationLifecycle: CaskApplicationLifecycle = .live) async throws -> [CaskRemovalFailure] {
        let requirement = try Self.runningCodeRequirement()
        let lease = FileManager.default.temporaryDirectory.appending(path: "cellar-removal-\(UUID().uuidString)")
        let descriptor = open(lease.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(descriptor)
        defer { unlink(lease.path) }
        let request = CaskRemovalAuthorizationRequest(userID: getuid(), home: CaskRemovalFileSystem.physicalURL(home).path,
            ownerPID: getpid(), expiresAt: Date().addingTimeInterval(290), lease: lease.path, entries: entries, removal: removal)
        try request.validate()
        let requestData = try JSONEncoder().encode(request)
        let requestFile = FileManager.default.temporaryDirectory.appending(path: "cellar-removal-req-\(UUID().uuidString).json")
        let reqFD = open(requestFile.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard reqFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { unlink(requestFile.path) }
        let handle = FileHandle(fileDescriptor: reqFD, closeOnDealloc: true)
        try handle.write(contentsOf: requestData)
        try handle.close()
        let process = ProcessRequest(executableURL: URL(filePath: "/usr/bin/osascript"),
            arguments: ["-e", Self.authorizationScript, Bundle.main.bundleURL.path, requirement, CaskRemovalPrivilegedMode.flag, requestFile.path],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path],
            currentDirectoryURL: home, timeout: .seconds(300))
        let output = try await applicationLifecycle.withApplicationsStopped(removal.applicationIdentities,
            onInvalidation: { unlink(lease.path) }, operation: {
                do { return try await runner.run(process) }
                catch let error as BridgeError {
                    guard case .processTimedOut = error else { throw error }
                    // This deadline bounds administrator cleanup, not a network request.
                    throw CaskRemovalAuthorizationError.timedOut(detail: error.localizedDescription)
                }
            })
        guard output.terminationStatus == 0, !output.standardOutputWasTruncated else {
            throw CaskRemovalAuthorizationError.failed(status: output.terminationStatus, detail: output.errorText)
        }
        return try JSONDecoder().decode([CaskRemovalFailure].self, from: output.standardOutput)
    }

    private static func runningCodeRequirement() throws -> String {
        func check(_ status: OSStatus) throws {
            guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        }
        var running: SecCode?
        try check(SecCodeCopySelf([], &running))
        guard let running else { throw CocoaError(.executableNotLoadable) }
        var code: SecStaticCode?
        try check(SecCodeCopyStaticCode(running, [], &code))
        guard let code else { throw CocoaError(.executableNotLoadable) }
        var information: CFDictionary?
        try check(SecCodeCopySigningInformation(code, [], &information))
        guard let values = information as? [String: Any], let hash = values[kSecCodeInfoUnique as String] as? Data,
              hash.count == 20 else { throw CocoaError(.executableNotLoadable) }
        let text = "cdhash H\"\(hash.map { String(format: "%02x", $0) }.joined())\""
        var requirement: SecRequirement?
        try check(SecRequirementCreateWithString(text as CFString, [], &requirement))
        // Dynamic validation binds the disk-derived hash to the actually running code, not a replaced App.
        try check(SecCodeCheckValidity(running, [], requirement))
        return text
    }

    // Arguments enter only through AppleScript's quoted form, never through source interpolation.
    static let authorizationScript = #"""
    on run argv
        set commandText to "set -eu
    umask 077
    staging=$(/usr/bin/mktemp -d /private/var/tmp/CellarAuthorized.XXXXXXXX)
    trap '/bin/rm -rf -- \"$staging\"' EXIT
    /usr/bin/ditto " & quoted form of (item 1 of argv) & " \"$staging/Cellar.app\"
    /usr/bin/codesign --verify --deep --strict -R " & quoted form of ("=" & (item 2 of argv)) & " \"$staging/Cellar.app\"
    \"$staging/Cellar.app/Contents/MacOS/Cellar\" " & quoted form of (item 3 of argv) & " " & quoted form of (item 4 of argv)
        do shell script commandText with administrator privileges
    end run
    """#
}

enum CaskRemovalPrivilegedMode {
    static let flag = "--cellar-authorized-cask-removal"

    static func run(arguments: [String]) -> Int32? {
        guard arguments.dropFirst().first == flag else { return nil }
        do {
            guard geteuid() == 0, arguments.count == 3 else { throw CocoaError(.fileWriteNoPermission) }
            let requestPath = arguments[2]
            let reqFD = open(requestPath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard reqFD >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            defer { close(reqFD) }
            var reqStatus = stat()
            guard fstat(reqFD, &reqStatus) == 0,
                  (reqStatus.st_mode & S_IFMT) == S_IFREG,
                  reqStatus.st_mode & 0o077 == 0,
                  reqStatus.st_nlink == 1,
                  reqStatus.st_size > 0,
                  reqStatus.st_size <= 4 * 1_024 * 1_024 else {
                throw CocoaError(.fileWriteNoPermission)
            }
            let reqHandle = FileHandle(fileDescriptor: reqFD, closeOnDealloc: false)
            let data = try reqHandle.read(upToCount: 4 * 1_024 * 1_024 + 1) ?? Data()
            guard data.count == Int(reqStatus.st_size) else { throw CocoaError(.fileWriteNoPermission) }
            let request = try JSONDecoder().decode(CaskRemovalAuthorizationRequest.self, from: data)
            guard reqStatus.st_uid == request.userID else { throw CocoaError(.fileWriteNoPermission) }
            try request.validate()
            let lease = open(request.lease, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard lease >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            defer { close(lease) }
            var status = stat()
            guard fstat(lease, &status) == 0, status.st_uid == request.userID,
                  (status.st_mode & S_IFMT) == S_IFREG, status.st_mode & 0o077 == 0, status.st_nlink == 1 else {
                throw CocoaError(.fileWriteNoPermission)
            }
            var failures: [CaskRemovalFailure] = []
            let scanner = CaskRemovalScanner(home: URL(filePath: request.home))
            func validateLease() throws {
                var current = stat()
                var path = stat()
                guard Date() < request.expiresAt, kill(request.ownerPID, 0) == 0,
                      fstat(lease, &current) == 0, current.st_nlink == 1,
                      lstat(request.lease, &path) == 0, path.st_dev == current.st_dev,
                      path.st_ino == current.st_ino else { throw CancellationError() }
            }
            let verification = try scanner.makeVerificationSession(request.removal)
            for entry in request.entries {
                do {
                    try validateLease()
                    guard try entry.category == .homebrewCache || verification.sharedDataRemainsProtected(),
                          try verification.cacheOwnershipIsUnchanged(entry) else {
                        throw HomebrewClientError.stateChanged
                    }
                    try CaskRemovalFileSystem.remove(entry, shouldContinue: validateLease)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    failures.append(.init(path: entry.path, error: error))
                }
            }
            let result = try JSONEncoder().encode(failures)
            FileHandle.standardOutput.write(result)
            return 0
        } catch {
            FileHandle.standardError.write(Data(error.localizedDescription.utf8))
            return 1
        }
    }
}
