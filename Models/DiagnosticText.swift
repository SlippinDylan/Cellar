import Foundation

enum DiagnosticText {
    static func sanitized(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)Bearer\s+[^\s]+"#, with: "Bearer [redacted]", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)(https?://)[^\s/@]+@"#, with: "$1[redacted]@", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)(token|password|secret|authorization|cookie|api[-_]?key)(\s*[:=]\s*)[^\s;,]+"#, with: "$1$2[redacted]", options: .regularExpression)
    }
}
