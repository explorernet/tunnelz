import Foundation

struct ReplayRequestDraft: Identifiable {
    let id = UUID()
    let tunnelID: UUID
    var method: String
    var path: String
    var headersText: String
    var body: String
    let isJSON: Bool

    init?(request: CapturedRequest) {
        guard let tunnelID = request.tunnel?.id else { return nil }
        self.tunnelID = tunnelID
        method = request.method
        path = request.path
        headersText = request.requestHeaders
            .map { "\($0.name): \($0.value)" }
            .joined(separator: "\n")
        let jsonObject = try? JSONSerialization.jsonObject(with: request.requestBody)
        isJSON = jsonObject != nil
            || request.requestHeaders.contains {
                $0.name.caseInsensitiveCompare("content-type") == .orderedSame
                    && $0.value.localizedCaseInsensitiveContains("json")
            }
        if let jsonObject,
           let formattedData = try? JSONSerialization.data(
               withJSONObject: jsonObject,
               options: [.prettyPrinted, .sortedKeys]
           ) {
            body = String(data: formattedData, encoding: .utf8) ?? ""
        } else {
            body = String(data: request.requestBody, encoding: .utf8) ?? ""
        }
    }

    var headers: [CapturedHeader] {
        headersText
            .split(whereSeparator: \Character.isNewline)
            .compactMap { line in
                guard let separator = line.firstIndex(of: ":") else { return nil }
                let name = line[..<separator].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return nil }
                return CapturedHeader(name: name, value: value)
            }
    }

    var isValid: Bool {
        !method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && path.hasPrefix("/")
    }
}
