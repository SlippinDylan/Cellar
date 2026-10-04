import Darwin
import Foundation

struct ShellConfigurationFile {
    let contents: Data
    let metadata: stat

    static func read(at url: URL) throws -> Self {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw BridgeError.managerFailure(code: "zshrc-not-regular-file", detail: nil) }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size <= 2 * 1_024 * 1_024 else {
            throw BridgeError.managerFailure(code: "zshrc-not-regular-file", detail: nil)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        return Self(contents: try handle.readToEnd() ?? Data(), metadata: metadata)
    }

    func matches(_ other: Self) -> Bool {
        contents == other.contents && metadata.st_ino == other.metadata.st_ino && metadata.st_dev == other.metadata.st_dev
            && metadata.st_mode == other.metadata.st_mode && metadata.st_uid == other.metadata.st_uid && metadata.st_gid == other.metadata.st_gid
            && metadata.st_flags == other.metadata.st_flags
            && metadata.st_mtimespec.tv_sec == other.metadata.st_mtimespec.tv_sec && metadata.st_mtimespec.tv_nsec == other.metadata.st_mtimespec.tv_nsec
    }

    func restore(at url: URL, replacing expectedContents: Data) throws {
        let descriptor = open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw BridgeError.managerFailure(code: "shell-restore-state-changed", detail: nil) }
        defer { close(descriptor) }
        var current = stat()
        guard fstat(descriptor, &current) == 0, current.st_mode & S_IFMT == S_IFREG else { throw BridgeError.managerFailure(code: "shell-restore-state-changed", detail: nil) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard try handle.readToEnd() == expectedContents, pathStillReferences(current, at: url) else { throw BridgeError.managerFailure(code: "shell-restore-state-changed", detail: nil) }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: contents)
        try handle.truncate(atOffset: UInt64(contents.count))
        guard fchown(descriptor, metadata.st_uid, metadata.st_gid) == 0, fchmod(descriptor, metadata.st_mode & 0o7777) == 0 else {
            throw BridgeError.managerFailure(code: "shell-restore-attributes-failed", detail: nil)
        }
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = UInt32(ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_ACCTIME)
        var dates = [metadata.st_birthtimespec, metadata.st_mtimespec, metadata.st_atimespec]
        let result = dates.withUnsafeMutableBytes { fsetattrlist(descriptor, &attributes, $0.baseAddress, $0.count, 0) }
        guard result == 0, fchflags(descriptor, metadata.st_flags) == 0, pathStillReferences(current, at: url) else { throw BridgeError.managerFailure(code: "shell-restore-attributes-failed", detail: nil) }
    }

    private func pathStillReferences(_ expected: stat, at url: URL) -> Bool {
        var current = stat()
        return lstat(url.path, &current) == 0 && current.st_mode & S_IFMT == S_IFREG
            && current.st_ino == expected.st_ino && current.st_dev == expected.st_dev
    }
}
