import Foundation

actor ProjectConfigurationService {
    func readNVMRC(in selectedDirectory: URL) throws -> String? {
        guard selectedDirectory.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let file = selectedDirectory.appending(path: ".nvmrc")
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: file.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int, size <= 4096 else { throw CocoaError(.fileReadUnknown) }
        return try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
