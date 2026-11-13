import Darwin
import Foundation

// Each bounded phase shares a budget; cancellation cannot interrupt an in-flight filesystem syscall.
final class CaskRemovalScanBudget {
    private let deadline: ContinuousClock.Instant
    private var remaining: Int

    init(entries: Int = 20_000, duration: Duration = .seconds(8)) {
        remaining = entries
        deadline = ContinuousClock.now.advanced(by: duration)
    }

    func check() throws {
        try Task.checkCancellation()
        guard remaining > 0, ContinuousClock.now < deadline else { throw POSIXError(.ETIMEDOUT) }
        remaining -= 1
    }
}

struct CaskRemovalVolume: Sendable {
    struct Identity: Sendable, Equatable {
        let first: Int32
        let second: Int32

        init(_ value: statfs) {
            first = value.f_fsid.val.0
            second = value.f_fsid.val.1
        }
    }

    let url: URL
    let identity: Identity
    let isLocal: Bool
}

// All deletion stays relative to opened directories; symlink ancestors are never followed.
enum CaskRemovalFileSystem {
    static func physicalURL(_ url: URL) -> URL {
        guard let path = realpath(url.path, nil) else {
            // Application/cache roots may not exist yet; resolve their existing ancestor.
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else { return url }
            return physicalURL(parent).appending(path: url.lastPathComponent)
        }
        defer { free(path) }
        return URL(filePath: String(cString: path))
    }

    static func isNormalized(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        return path.hasPrefix("/") && !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
            && !path.utf8.contains(0)
    }

    static func fingerprint(_ path: String) throws -> String {
        let (parent, name) = try openParent(path)
        defer { close(parent) }
        return try identity(parent: parent, name: name)
    }

    static func exists(_ path: String) -> Bool {
        do { return try isPresent(path) }
        catch { return true } // Unreadable paths remain candidates for the strict identity check.
    }

    static func isPresent(_ path: String) throws -> Bool {
        do {
            let (parent, name) = try openParent(path)
            defer { close(parent) }
            var value = stat()
            if fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return true }
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            if code == .ENOENT { return false }
            throw POSIXError(code)
        } catch let error as POSIXError where error.code == .ENOENT { return false }
    }

    // Foundation standardization can rewrite /private/var; cache identity needs lexical normalization only.
    static func lexicalURL(_ path: String) -> URL? {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else { return nil }
                components.removeLast()
            } else { components.append(component) }
        }
        return URL(filePath: "/" + components.joined(separator: "/"))
    }

    static func readRegularFile(_ path: String, limit: Int, shouldContinue: () throws -> Void = { try Task.checkCancellation() }) throws -> Data {
        try shouldContinue()
        let (parent, name) = try openParent(path)
        defer { close(parent) }
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size >= 0, before.st_size <= limit else { throw POSIXError(.EINVAL) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count <= limit {
            try Task.checkCancellation()
            try shouldContinue()
            let count = read(descriptor, &buffer, min(buffer.count, limit + 1 - data.count))
            if count < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        var current = stat()
        guard data.count <= limit, fstat(descriptor, &after) == 0,
              fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_dev == current.st_dev, before.st_ino == current.st_ino,
              after.st_size == data.count,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw HomebrewClientError.stateChanged }
        return data
    }

    static func remove(_ entry: CaskRemovalEntry, shouldContinue: () throws -> Void = {}) throws {
        let (parent, name) = try openParent(entry.path)
        defer { close(parent) }
        guard try identity(parent: parent, name: name) == entry.fingerprint else {
            throw HomebrewClientError.stateChanged
        }
        var visited = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        try remove(parent: parent, name: name, expected: entry.fingerprint, depth: 0) {
            try shouldContinue()
            visited += 1
            guard visited < 200_000, ContinuousClock.now < deadline else { throw POSIXError(.ETIMEDOUT) }
        }
    }

    struct ScanNode {
        let path: String
        let mode: mode_t
        let bytes: Int64
        var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
        var isSymbolicLink: Bool { mode & S_IFMT == S_IFLNK }
        var isRegularFile: Bool { mode & S_IFMT == S_IFREG }
    }

    // FD-relative enumeration never traverses symlinks or another mounted filesystem.
    static func walk(_ path: String, budget: CaskRemovalScanBudget, volume: CaskRemovalVolume? = nil,
                     visit: (ScanNode, Int) throws -> Bool) throws {
        try budget.check()
        if let volume {
            guard volume.isLocal, path == volume.url.path || path.hasPrefix(volume.url.path + "/") else { throw POSIXError(.EXDEV) }
        } else {
            guard !path.hasPrefix("/Volumes/") else { throw POSIXError(.EXDEV) }
        }
        let (parent, name) = try openParent(path)
        defer { close(parent) }
        var parentVolume = statfs()
        guard fstatfs(parent, &parentVolume) == 0, parentVolume.f_flags & UInt32(MNT_LOCAL) != 0 else { throw POSIXError(.EXDEV) }
        var value = stat()
        var parentValue = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0, fstat(parent, &parentValue) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if let volume {
            guard try localVolumeIdentity(path) == volume.identity else { throw POSIXError(.EXDEV) }
        } else {
            guard value.st_dev == parentValue.st_dev else { throw POSIXError(.EXDEV) }
        }
        try walk(parent: parent, name: name, path: path, device: value.st_dev, depth: 0, budget: budget, visit: visit)
    }

    static func localVolumeIdentity(_ path: String) throws -> CaskRemovalVolume.Identity {
        let (parent, name) = try openParent(path)
        defer { close(parent) }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var value = statfs()
        guard fstatfs(descriptor, &value) == 0, value.f_flags & UInt32(MNT_LOCAL) != 0 else { throw POSIXError(.EXDEV) }
        return CaskRemovalVolume.Identity(value)
    }

    private static func walk(parent: Int32, name: String, path: String, device: dev_t, depth: Int,
                             budget: CaskRemovalScanBudget, visit: (ScanNode, Int) throws -> Bool) throws {
        try budget.check()
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard value.st_dev == device, depth < 64 else { throw POSIXError(.EXDEV) }
        let node = ScanNode(path: path, mode: value.st_mode, bytes: Int64(value.st_blocks) * 512)
        guard try visit(node, depth), node.isDirectory else { return }
        try budget.check()
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var opened = stat()
        var volume = statfs()
        guard fstat(descriptor, &opened) == 0, opened.st_dev == device, opened.st_ino == value.st_ino,
              fstatfs(descriptor, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0 else { throw POSIXError(.EXDEV) }
        guard let directory = fdopendir(dup(descriptor)) else { throw POSIXError(.EIO) }
        defer { closedir(directory) }
        while true {
            try budget.check()
            errno = 0
            guard let record = readdir(directory) else {
                guard errno == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                break
            }
            let child = withUnsafePointer(to: &record.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if child == "." || child == ".." { continue }
            try walk(parent: descriptor, name: child, path: path + "/" + child, device: device,
                     depth: depth + 1, budget: budget, visit: visit)
        }
    }

    static func verifyDirectoryReadAccess(_ path: String) throws {
        try Task.checkCancellation()
        let (parent, name) = try openParent(path)
        defer { close(parent) }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var volume = statfs()
        var opened = stat()
        var parentInfo = stat()
        guard fstatfs(descriptor, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0,
              fstat(descriptor, &opened) == 0, fstat(parent, &parentInfo) == 0,
              opened.st_dev == parentInfo.st_dev else {
            close(descriptor)
            throw POSIXError(.EXDEV)
        }
        guard let directory = fdopendir(descriptor) else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(descriptor)
            throw POSIXError(code)
        }
        defer { closedir(directory) }
        try Task.checkCancellation()
        // Verify a single directory read; never enumerate the whole folder or read file contents.
        errno = 0
        _ = readdir(directory)
        guard errno == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func measureAllocatedSize(_ path: String, budget: CaskRemovalScanBudget) throws -> Int64 {
        var total: Int64 = 0
        try walk(path, budget: budget) { node, _ in
            if node.isRegularFile { total += node.bytes }
            return true
        }
        return total
    }

    static func allocatedSize(_ path: String, budget: CaskRemovalScanBudget = .init(entries: 10_000, duration: .seconds(2))) throws -> Int64? {
        do { return try measureAllocatedSize(path, budget: budget) }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    private static func openParent(_ path: String) throws -> (Int32, String) {
        let url = URL(filePath: path)
        guard isNormalized(path), let name = url.pathComponents.last else { throw HomebrewClientError.stateChanged }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            for component in url.deletingLastPathComponent().pathComponents.dropFirst() {
                try Task.checkCancellation()
                var volume = statfs()
                guard fstatfs(descriptor, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0 else { throw POSIXError(.EXDEV) }
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                close(descriptor)
                descriptor = next
            }
            return (descriptor, name)
        } catch { close(descriptor); throw error }
    }

    private static func identity(parent: Int32, name: String) throws -> String {
        var value = stat()
        var parentValue = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard fstat(parent, &parentValue) == 0, value.st_dev == parentValue.st_dev else { throw POSIXError(.EXDEV) }
        let node = "\(value.st_dev):\(value.st_ino):\(value.st_mode):\(value.st_birthtimespec.tv_sec):\(value.st_birthtimespec.tv_nsec)"
        if (value.st_mode & S_IFMT) == S_IFDIR { return node }
        return node + ":\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
    }

    private static func remove(parent: Int32, name: String, expected: String, depth: Int,
                               shouldContinue: () throws -> Void) throws {
        try Task.checkCancellation()
        try shouldContinue()
        guard depth < 256 else { throw POSIXError(.ELOOP) }
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard try identity(parent: parent, name: name) == expected else { throw HomebrewClientError.stateChanged }
        if (value.st_mode & S_IFMT) == S_IFDIR {
            let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, opened.st_dev == value.st_dev, opened.st_ino == value.st_ino else {
                throw HomebrewClientError.stateChanged
            }
            guard let directory = fdopendir(dup(descriptor)) else { throw POSIXError(.EIO) }
            defer { closedir(directory) }
            while true {
                errno = 0
                guard let record = readdir(directory) else {
                    guard errno == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    break
                }
                let child = withUnsafePointer(to: &record.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if child == "." || child == ".." { continue }
                try remove(parent: descriptor, name: child, expected: identity(parent: descriptor, name: child),
                           depth: depth + 1, shouldContinue: shouldContinue)
            }
        }
        guard try identity(parent: parent, name: name) == expected else { throw HomebrewClientError.stateChanged }
        try shouldContinue()
        guard unlinkat(parent, name, (value.st_mode & S_IFMT) == S_IFDIR ? AT_REMOVEDIR : 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
