import Foundation

/// Builds a `curl` command that repeats a captured request against the tunnel's address.
enum CURLCommand {
    static func make(for request: CapturedRequest, publicURL: URL?, localURL: String?) -> String {
        let url = publicURL?.appending(path: request.path).absoluteString
            ?? "http://\(localURL ?? "localhost")\(request.path)"
        var arguments = [
            "curl",
            "--request \(shellQuote(request.method))",
            "--url \(shellQuote(url))"
        ]

        for header in request.requestHeaders where !omittedHeaders.contains(header.name.lowercased()) {
            arguments.append("--header \(shellQuote("\(header.name): \(header.value)"))")
        }

        if !request.requestBody.isEmpty,
           request.method.caseInsensitiveCompare("GET") != .orderedSame,
           request.method.caseInsensitiveCompare("HEAD") != .orderedSame,
           let body = String(data: request.requestBody, encoding: .utf8) {
            arguments.append("--data-raw \(shellQuote(body))")
        }

        return arguments.joined(separator: " \\\n  ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static let omittedHeaders: Set<String> = [
        "connection", "content-length", "host", "keep-alive", "proxy-authenticate",
        "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade",
        "x-inspector-replay"
    ]
}
