import Darwin
import Foundation

// Bounds apply to the opened file, including growth while it is being read.
struct NodeConfigurationFile {
    let contents: Data
    let identity: String

    static func read(at url: URL, maximumBytes: Int) throws -> Self? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw BridgeError.managerFailure(code: "node-configuration-unsafe", detail: nil)
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= maximumBytes else {
            throw BridgeError.managerFailure(code: "node-configuration-unsafe", detail: nil)
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count <= maximumBytes {
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, maximumBytes + 1 - data.count))
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw BridgeError.managerFailure(code: "node-configuration-read-failed", detail: nil) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        var path = stat()
        guard data.count <= maximumBytes, fstat(descriptor, &after) == 0, lstat(url.path, &path) == 0,
              sameFile(before, after), sameFile(after, path), after.st_size == data.count else {
            throw BridgeError.managerFailure(code: "node-configuration-changed", detail: nil)
        }
        return Self(contents: data, identity: "\(after.st_dev):\(after.st_ino):\(after.st_mode):\(after.st_size):\(after.st_mtimespec.tv_sec):\(after.st_mtimespec.tv_nsec):\(after.st_ctimespec.tv_sec):\(after.st_ctimespec.tv_nsec)")
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
