import Foundation

/// Limits and privacy options from Settings → General. Read from any thread (UserDefaults is thread-safe).
nonisolated enum AppSettings {
    static let maxRequestBodyMBKey = "general.maxRequestBodyMB"
    static let maxCapturedBodyKBKey = "general.maxCapturedBodyKB"
    static let requestHistoryLimitKey = "general.requestHistoryLimit"
    static let redactsSensitiveHeadersKey = "general.redactsSensitiveHeaders"

    static let defaultMaxRequestBodyMB = 100
    static let defaultMaxCapturedBodyKB = 1_024
    static let defaultRequestHistoryLimit = 1_000
    static let defaultRedactsSensitiveHeaders = false

    /// Largest request body the proxy accepts; bigger requests get 413.
    static var maxRequestBodyBytes: Int {
        integer(maxRequestBodyMBKey, default: defaultMaxRequestBodyMB, range: 1...10_240) * 1_048_576
    }

    /// How much of each request and response body is kept in the history.
    static var maxCapturedBodyBytes: Int {
        integer(maxCapturedBodyKBKey, default: defaultMaxCapturedBodyKB, range: 0...102_400) * 1_024
    }

    /// Unsaved requests kept per tunnel; older ones are deleted.
    static var requestHistoryLimit: Int {
        integer(requestHistoryLimitKey, default: defaultRequestHistoryLimit, range: 10...100_000)
    }

    static var redactsSensitiveHeaders: Bool {
        UserDefaults.standard.object(forKey: redactsSensitiveHeadersKey) as? Bool ?? defaultRedactsSensitiveHeaders
    }

    static let sensitiveHeaders: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key"
    ]

    /// Masks credentials before a header is stored, when the user asked for it.
    static func headersForCapture(_ headers: [CapturedHeader]) -> [CapturedHeader] {
        guard redactsSensitiveHeaders else { return headers }
        return headers.map { header in
            sensitiveHeaders.contains(header.name.lowercased())
                ? CapturedHeader(name: header.name, value: "•••••• (redacted)")
                : header
        }
    }

    private static func integer(_ key: String, default defaultValue: Int, range: ClosedRange<Int>) -> Int {
        let value = UserDefaults.standard.object(forKey: key) as? Int ?? defaultValue
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
