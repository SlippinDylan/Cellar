import Combine
import Darwin
import Foundation

enum LogLevel: Int, CaseIterable, Comparable, Sendable {
    case trace, debug, info, warning, error, critical

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .trace: "TRACE"
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        case .critical: "CRITICAL"
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .trace: "Trace"
        case .debug: "Debug"
        case .info: "Info"
        case .warning: "Warning"
        case .error: "Error"
        case .critical: "Critical"
        }
    }
}

enum LogRetention: Int, CaseIterable, Sendable {
    case sevenDays = 7, fourteenDays = 14, thirtyDays = 30

    var title: LocalizedStringResource {
        switch self {
        case .sevenDays: "7 Days"
        case .fourteenDays: "14 Days"
        case .thirtyDays: "30 Days"
        }
    }
}

@MainActor
final class FileLogStore: ObservableObject {
    @Published var minimumLevel: LogLevel {
        didSet {
            defaults.set(minimumLevel.rawValue, forKey: Self.minimumLevelKey)
            enqueue(record: nil)
        }
    }
    @Published var retention: LogRetention {
        didSet {
            defaults.set(retention.rawValue, forKey: Self.retentionKey)
            enqueue(record: nil)
        }
    }
    @Published private(set) var errorMessage: String?
    let directory: URL

    static let minimumLevelKey = "logging.minimumLevel"
    static let retentionKey = "logging.retentionDays"
    private let defaults: UserDefaults
    private let now: @MainActor () -> Date
    private let writer: LogFileWriter
    private var pendingWrite: Task<Void, Never>?
    private var writeGeneration = 0

    init(directory: URL, defaults: UserDefaults, maximumFileBytes: Int = 10 * 1024 * 1024,
         maximumTotalBytes: Int = 50 * 1024 * 1024, now: @escaping @MainActor () -> Date = Date.init) {
        precondition(maximumFileBytes > 0 && maximumTotalBytes >= maximumFileBytes)
        self.directory = directory
        self.defaults = defaults
        self.now = now
        minimumLevel = defaults.object(forKey: Self.minimumLevelKey).flatMap { $0 as? Int }.flatMap(LogLevel.init(rawValue:)) ?? .info
        retention = LogRetention(rawValue: defaults.integer(forKey: Self.retentionKey)) ?? .sevenDays
        writer = LogFileWriter(directory: directory, maximumFileBytes: maximumFileBytes, maximumTotalBytes: maximumTotalBytes)
    }

    func record(level: LogLevel, category: String, message: String, taskID: UUID? = nil) {
        guard level >= minimumLevel else { return }
        let date = now()
        let timestamp = date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: true).timeZone(separator: .colon))
        let category = Self.safeText(category, limit: 120)
        let message = Self.safeText(message, limit: 4_000)
        let identifier = taskID.map { " task=\($0.uuidString)" } ?? ""
        let line = "\(timestamp) [\(level.label)] [\(category)]\(identifier) \(message)\n"
        enqueue(record: FileLogRecord(date: date, data: Data(line.utf8), synchronize: level >= .error))
    }

    func retry() { enqueue(record: nil) }

    func flush() async {
        // New records can arrive while a previous write is suspended on the file actor.
        while true {
            let generation = writeGeneration
            await pendingWrite?.value
            if generation == writeGeneration { return }
        }
    }

    private func enqueue(record: FileLogRecord?) {
        writeGeneration += 1
        let previous = pendingWrite
        let date = now()
        let retentionDays = retention.rawValue
        pendingWrite = Task {
            await previous?.value
            do {
                try await writer.write(record, now: date, retentionDays: retentionDays)
                errorMessage = nil
            } catch {
                errorMessage = DiagnosticText.sanitized(error.localizedDescription)
            }
        }
    }

    private static func safeText(_ text: String, limit: Int) -> String {
        // Sanitize before truncation so a clipped secret cannot evade a complete-token rule.
        let sanitized = DiagnosticText.sanitized(String(text.prefix(64_000)))
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return String(sanitized.prefix(limit))
    }
}

private struct FileLogRecord: Sendable {
    let date: Date
    let data: Data
    let synchronize: Bool
}

private actor LogFileWriter {
    private let directory: URL
    private let maximumFileBytes: Int
    private let maximumTotalBytes: Int
    private var pending: [FileLogRecord] = []
    private var omittedRecords = 0
    private let formatter: DateFormatter

    init(directory: URL, maximumFileBytes: Int, maximumTotalBytes: Int) {
        self.directory = directory
        self.maximumFileBytes = maximumFileBytes
        self.maximumTotalBytes = maximumTotalBytes
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        self.formatter = formatter
    }

    func write(_ record: FileLogRecord?, now: Date, retentionDays: Int) throws {
        if let record {
            pending.append(record)
            // Bound memory during prolonged disk failures; report omissions after recovery.
            while pending.count > 256 {
                pending.removeFirst()
                omittedRecords += 1
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try cleanup(now: now, retentionDays: retentionDays)
        if omittedRecords > 0 {
            let warning = Data("\(now.formatted(.iso8601)) [WARN] [logging] \(omittedRecords) log entries omitted while storage was unavailable.\n".utf8)
            try append(.init(date: now, data: warning, synchronize: true))
            omittedRecords = 0
        }
        while let first = pending.first {
            try append(first)
            pending.removeFirst()
        }
        try cleanup(now: now, retentionDays: retentionDays)
    }

    private func append(_ record: FileLogRecord) throws {
        let day = formatter.string(from: record.date)
        let prefix = "cellar-\(day)"
        let files = try ownedFiles().filter { $0.day == day }.sorted { $0.sequence < $1.sequence }
        let latest = files.last
        let data = boundedLine(record.data)
        let sequence: Int
        if let latest, latest.size + data.count <= maximumFileBytes {
            sequence = latest.sequence
        } else {
            sequence = latest.map { $0.sequence + 1 } ?? 0
        }
        let name = sequence == 0 ? "\(prefix).log" : "\(prefix)-\(sequence).log"
        let url = directory.appendingPathComponent(name)
        // Validate the opened object, not an earlier path lookup; a FIFO must never block flushing.
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            close(descriptor)
            throw error
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            if record.synchronize { try handle.synchronize() }
        } catch {
            // Closing is cleanup; retain the original IO error for the user.
            try? handle.close()
            throw error
        }
        try handle.close()
    }

    private func boundedLine(_ data: Data) -> Data {
        guard data.count > maximumFileBytes else { return data }
        // Keep UTF-8 valid even when tests or future callers use a smaller file limit.
        let text = String(decoding: data, as: UTF8.self)
        var prefix = ""
        for character in text {
            guard prefix.utf8.count + character.utf8.count + 1 <= maximumFileBytes else { break }
            prefix.append(character)
        }
        return Data((prefix + "\n").utf8)
    }

    private func cleanup(now: Date, retentionDays: Int) throws {
        let cutoff = formatter.string(from: now.addingTimeInterval(-Double(retentionDays) * 86_400))
        var files = try ownedFiles()
        for file in files where file.day <= cutoff {
            try FileManager.default.removeItem(at: file.url)
        }
        files.removeAll { $0.day <= cutoff }
        files.sort { $0.day == $1.day ? $0.sequence < $1.sequence : $0.day < $1.day }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files where total > maximumTotalBytes {
            try FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    private struct LogFile {
        let url: URL
        let day: String
        let sequence: Int
        let size: Int
    }

    private func ownedFiles() throws -> [LogFile] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)).compactMap { url in
            let name = url.lastPathComponent
            guard name.range(of: #"^cellar-\d{4}-\d{2}-\d{2}(?:-\d+)?\.log$"#, options: .regularExpression) != nil else { return nil }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            let day = String(name.dropFirst(7).prefix(10))
            let suffix = String(name.dropFirst(17).dropLast(4))
            let sequence = suffix.isEmpty ? 0 : Int(suffix.dropFirst())
            guard let sequence, let size = values.fileSize else { return nil }
            return LogFile(url: url, day: day, sequence: sequence, size: size)
        }
    }
}
