import Foundation

actor ProjectConfigurationService {
    func readNVMRC(in selectedDirectory: URL) throws -> String? {
        guard selectedDirectory.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let file = selectedDirectory.appending(path: ".nvmrc")
        guard let snapshot = try NodeConfigurationFile.read(at: file, maximumBytes: 4096) else { return nil }
        guard let text = String(data: snapshot.contents, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
