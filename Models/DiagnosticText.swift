import Foundation

enum DiagnosticText {
    static func sanitized(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?is)-----BEGIN [^-]*PRIVATE KEY-----.*?(?:-----END [^-]*PRIVATE KEY-----|$)"#, with: "[redacted private key]", options: .regularExpression)
            .replacingOccurrences(of: #"(?im)\b(?:set-cookie|cookie|authorization)\s*:\s*[^\r\n]*"#, with: "[redacted header]", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)Bearer\s+[^\s]+"#, with: "Bearer [redacted]", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)(https?://)[^\s/@]+@"#, with: "$1[redacted]@", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\b([a-z0-9_-]*(?:token|password|secret|authorization|cookie|api[-_]?key)[a-z0-9_-]*)([\"']?\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s;&,]+)"#, with: "$1$2[redacted]", options: .regularExpression)
            .replacingOccurrences(of: #"(?:/Users/|/home/)[^\s\"'<>]+"#, with: "[private path]", options: .regularExpression)
            .replacingOccurrences(of: #"\b(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|npm_[A-Za-z0-9]+|sk-[A-Za-z0-9_-]{12,})\b"#, with: "[redacted token]", options: .regularExpression)
    }
}
