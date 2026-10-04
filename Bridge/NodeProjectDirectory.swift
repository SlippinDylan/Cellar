import Darwin
import Foundation

// Session-only identity; child-file absence must not erase the selected directory.
struct NodeProjectDirectory: Equatable, Sendable {
    let canonicalURL: URL
    private let device: dev_t
    private let inode: ino_t
    private let owner: uid_t
    private let group: gid_t
    private let mode: mode_t
    private let birthSeconds: Int
    private let birthNanoseconds: Int

    static func read(selectedPath: String) throws -> Self {
        guard selectedPath.hasPrefix("/"), selectedPath.utf8.count < MAXPATHLEN,
              !selectedPath.contains("\0"),
              !selectedPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw changed }
        // Remove a trailing separator so O_NOFOLLOW still applies to the directory itself.
        let selected = URL(filePath: selectedPath).standardizedFileURL
        let descriptor = open(selected.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw changed }
        defer { close(descriptor) }
        var metadata = stat()
        var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
              fcntl(descriptor, F_GETPATH, &path) == 0,
              let canonicalPath = String(validating: path.prefix { $0 != 0 }, as: UTF8.self), canonicalPath.hasPrefix("/") else { throw changed }
        let canonical = URL(filePath: canonicalPath, directoryHint: .isDirectory)
        let identity = Self(canonicalURL: canonical, metadata: metadata)
        var selectedMetadata = stat()
        var canonicalMetadata = stat()
        guard lstat(selected.path, &selectedMetadata) == 0, lstat(canonical.path, &canonicalMetadata) == 0,
              identity == Self(canonicalURL: canonical, metadata: selectedMetadata),
              identity == Self(canonicalURL: canonical, metadata: canonicalMetadata) else { throw changed }
        return identity
    }

    func requireUnchanged(selectedPath: String) throws {
        guard self == (try Self.read(selectedPath: selectedPath)),
              self == (try Self.read(selectedPath: canonicalURL.path)) else { throw Self.changed }
    }

    private init(canonicalURL: URL, metadata: stat) {
        self.canonicalURL = canonicalURL
        device = metadata.st_dev
        inode = metadata.st_ino
        owner = metadata.st_uid
        group = metadata.st_gid
        mode = metadata.st_mode
        birthSeconds = metadata.st_birthtimespec.tv_sec
        birthNanoseconds = metadata.st_birthtimespec.tv_nsec
    }

    private static var changed: BridgeError { .managerFailure(code: "project-changed", detail: nil) }
}
