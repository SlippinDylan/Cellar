import Darwin
import Foundation

// Own only the private staging directory. A published plugin is never deleted.
final class ShellPluginStaging {
    let directory: URL
    let token = UUID().uuidString
    let identity: String
    private let parent: Int32
    private let staging: Int32
    private let name: String
    private let metadata: stat
    private let home: URL
    private var publishedIdentity: stat?

    init(home: URL) throws {
        self.home = home
        var parent = open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Self.failure }
        do {
            for component in [".oh-my-zsh", "custom", "plugins"] {
                if component != ".oh-my-zsh", mkdirat(parent, component, 0o755) != 0, errno != EEXIST { throw Self.failure }
                let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Self.failure }
                close(parent)
                parent = next
            }
            name = ".cellar-plugin-\(token)"
            directory = home.appending(path: ".oh-my-zsh/custom/plugins/\(name)")
            guard mkdirat(parent, name, 0o700) == 0 else { throw Self.failure }
            let staging = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard staging >= 0 else { throw Self.failure }
            var metadata = stat()
            guard fstat(staging, &metadata) == 0 else { close(staging); throw Self.failure }
            let marker = openat(staging, ".cellar-owner", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard marker >= 0 else { close(staging); throw Self.failure }
            let markerValue = token
            let written = markerValue.withCString { write(marker, $0, markerValue.utf8.count) }
            close(marker)
            guard written == token.utf8.count else { close(staging); throw Self.failure }
            self.parent = parent
            self.staging = staging
            self.metadata = metadata
            identity = "\(metadata.st_dev):\(metadata.st_ino)"
        } catch { close(parent); throw error }
    }

    deinit { close(staging); close(parent) }

    func publish(name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), ownsStaging(), parentStillApproved() else { throw Self.failure }
        var clone = stat()
        guard fstatat(staging, "repository", &clone, AT_SYMLINK_NOFOLLOW) == 0, clone.st_mode & S_IFMT == S_IFDIR,
              renameatx_np(staging, "repository", parent, name, UInt32(RENAME_EXCL)) == 0 else { throw Self.failure }
        publishedIdentity = clone
    }

    func verifyPublished(name: String) throws {
        guard let publishedIdentity else { preconditionFailure("Publication must precede verification") }
        var current = stat()
        guard parentStillApproved(), fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_mode & S_IFMT == S_IFDIR, current.st_ino == publishedIdentity.st_ino, current.st_dev == publishedIdentity.st_dev else { throw Self.failure }
    }

    func cleanup() throws {
        guard ownsStaging() else { throw Self.failure }
        // Stay relative to retained descriptors even if an ancestor is renamed.
        // Cancellation must not skip cleanup of this owned, unpublished clone.
        var repository = stat()
        if fstatat(staging, "repository", &repository, AT_SYMLINK_NOFOLLOW) == 0 {
            try removeRepositoryEntry(parent: staging, name: "repository", expected: repository, depth: 0)
        } else if errno != ENOENT {
            throw Self.cleanupFailure(operation: "fstatat", name: "repository")
        }
        guard unlinkat(staging, ".cellar-owner", 0) == 0,
              unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw Self.failure }
    }

    private func removeRepositoryEntry(parent: Int32, name: String, expected: stat, depth: Int) throws {
        guard depth < 256 else { throw POSIXError(.ELOOP) }
        guard expected.st_dev == metadata.st_dev else { throw POSIXError(.EXDEV) }
        if expected.st_mode & S_IFMT == S_IFDIR {
            let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw Self.cleanupFailure(operation: "openat", name: name) }
            defer { close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0 else { throw Self.cleanupFailure(operation: "fstat", name: name) }
            guard Self.sameIdentity(opened, expected) else { throw Self.failure }
            let duplicate = dup(descriptor)
            guard duplicate >= 0 else { throw Self.cleanupFailure(operation: "dup", name: name) }
            guard let directory = fdopendir(duplicate) else {
                let error = Self.cleanupFailure(operation: "fdopendir", name: name)
                close(duplicate)
                throw error
            }
            defer { closedir(directory) }
            while true {
                errno = 0
                guard let record = readdir(directory) else {
                    guard errno == 0 else { throw Self.cleanupFailure(operation: "readdir", name: name) }
                    break
                }
                let child = withUnsafePointer(to: &record.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if child == "." || child == ".." { continue }
                var value = stat()
                guard fstatat(descriptor, child, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw Self.cleanupFailure(operation: "fstatat", name: child)
                }
                try removeRepositoryEntry(parent: descriptor, name: child, expected: value, depth: depth + 1)
            }
        }
        var current = stat()
        guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw Self.cleanupFailure(operation: "fstatat", name: name)
        }
        guard Self.sameIdentity(current, expected) else { throw Self.failure }
        guard unlinkat(parent, name, expected.st_mode & S_IFMT == S_IFDIR ? AT_REMOVEDIR : 0) == 0 else {
            throw Self.cleanupFailure(operation: "unlinkat", name: name)
        }
    }

    private static func sameIdentity(_ current: stat, _ expected: stat) -> Bool {
        current.st_dev == expected.st_dev && current.st_ino == expected.st_ino
            && current.st_mode & S_IFMT == expected.st_mode & S_IFMT
    }

    private static func cleanupFailure(operation: String, name: String) -> POSIXError {
        let code = POSIXErrorCode(rawValue: errno) ?? .EIO
        let reason = POSIXError(code).localizedDescription
        return POSIXError(code, userInfo: [NSLocalizedDescriptionKey: "Plugin staging \(operation) (\(name)): \(reason)"])
    }

    private func ownsStaging() -> Bool {
        var current = stat()
        guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_mode & S_IFMT == S_IFDIR, current.st_ino == metadata.st_ino, current.st_dev == metadata.st_dev else { return false }
        let marker = openat(staging, ".cellar-owner", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard marker >= 0 else { return false }
        defer { close(marker) }
        var markerStat = stat()
        guard fstat(marker, &markerStat) == 0, markerStat.st_mode & S_IFMT == S_IFREG, markerStat.st_size == token.utf8.count else { return false }
        var buffer = [UInt8](repeating: 0, count: token.utf8.count + 1)
        let count = read(marker, &buffer, buffer.count)
        return count == token.utf8.count && String(bytes: buffer.prefix(count), encoding: .utf8) == token
    }

    private func parentStillApproved() -> Bool {
        var descriptor = open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        for component in [".oh-my-zsh", "custom", "plugins"] {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return false }
            close(descriptor)
            descriptor = next
        }
        var approved = stat()
        var current = stat()
        return fstat(parent, &approved) == 0 && fstat(descriptor, &current) == 0
            && approved.st_ino == current.st_ino && approved.st_dev == current.st_dev
    }

    private static var failure: BridgeError { .managerFailure(code: "plugin-staging-state-changed", detail: nil) }
}
