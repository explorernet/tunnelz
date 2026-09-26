import Foundation
import SwiftData

enum TunnelRuntimePhase: String {
    case stopped
    case starting
    case running
    case stopping
    case error
}

enum TunnelProvider: String, Codable {
    /// Temporary *.trycloudflare.com address via cloudflared.
    case quick
    /// Permanent <relayName>.<relay domain> address via the relay.
    case relay
}

@Model
final class Tunnel {
    @Attribute(.unique) var id: UUID
    var name: String
    var localPort: Int
    var domain: String
    var providerRawValue: String = TunnelProvider.quick.rawValue
    var relayName: String?
    var startsAutomatically: Bool
    /// JSON-encoded `[TunnelRoute]`; unmatched requests go to `localPort`.
    var routesData: Data?
    /// Whether requests through this tunnel are recorded in the inspector.
    var capturesRequests: Bool = true
    var createdAt: Date
    var runtimeProcessID: Int?
    var runtimeProxyPort: Int?
    var runtimePublicURL: String?
    var runtimeExecutablePath: String?
    @Relationship(deleteRule: .cascade, inverse: \CapturedRequest.tunnel)
    var requests: [CapturedRequest] = []

    init(
        id: UUID = UUID(),
        name: String,
        localPort: Int,
        domain: String = "trycloudflare.com",
        provider: TunnelProvider = .quick,
        relayName: String? = nil,
        startsAutomatically: Bool = true,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.localPort = localPort
        self.domain = domain
        providerRawValue = provider.rawValue
        self.relayName = relayName
        self.startsAutomatically = startsAutomatically
        self.createdAt = createdAt
        runtimeProcessID = nil
        runtimeProxyPort = nil
        runtimePublicURL = nil
        runtimeExecutablePath = nil
    }

    var localURL: String { "localhost:\(localPort)" }

    var routes: [TunnelRoute] {
        get { routesData.flatMap { try? JSONDecoder().decode([TunnelRoute].self, from: $0) } ?? [] }
        set { routesData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    var provider: TunnelProvider {
        TunnelProvider(rawValue: providerRawValue) ?? .quick
    }

    /// Known up front for relay tunnels; quick tunnels only learn theirs after starting.
    var relayURL: URL? {
        guard provider == .relay, let relayName else { return nil }
        return URL(string: "https://\(relayName).\(domain)")
    }
}

@Model
final class CapturedRequest {
    @Attribute(.unique) var id: UUID
    var method: String
    var path: String
    var status: Int
    var isReplay: Bool = false
    /// Bookmarked from the inspector; kept when old requests are trimmed.
    var isSaved: Bool = false
    var startedAt: Date
    var durationMilliseconds: Int
    var requestHeaders: [CapturedHeader]
    @Attribute(.externalStorage) var requestBody: Data
    var responseHeaders: [CapturedHeader]
    @Attribute(.externalStorage) var responseBody: Data
    var tunnel: Tunnel?

    init(exchange: CapturedExchange, tunnel: Tunnel) {
        id = exchange.id
        method = exchange.method
        path = exchange.path
        status = exchange.status
        isReplay = exchange.isReplay
        startedAt = exchange.startedAt
        durationMilliseconds = exchange.durationMilliseconds
        requestHeaders = exchange.requestHeaders
        requestBody = exchange.requestBody
        responseHeaders = exchange.responseHeaders
        responseBody = exchange.responseBody
        self.tunnel = tunnel
    }
    var duration: String { "\(durationMilliseconds) ms" }
    var time: String {
        startedAt.formatted(
            .dateTime
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
                .second(.twoDigits)
        )
    }
    var pathWithoutQuery: String {
        String(path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
    }
}

struct CapturedExchange: Sendable {
    let id: UUID
    let tunnelID: UUID
    let method: String
    let path: String
    let status: Int
    let isReplay: Bool
    let startedAt: Date
    let durationMilliseconds: Int
    let requestHeaders: [CapturedHeader]
    let requestBody: Data
    let responseHeaders: [CapturedHeader]
    let responseBody: Data

    init(
        id: UUID = UUID(),
        tunnelID: UUID,
        method: String,
        path: String,
        status: Int,
        isReplay: Bool = false,
        startedAt: Date,
        durationMilliseconds: Int,
        requestHeaders: [CapturedHeader],
        requestBody: Data,
        responseHeaders: [CapturedHeader],
        responseBody: Data
    ) {
        self.id = id
        self.tunnelID = tunnelID
        self.method = method
        self.path = path
        self.status = status
        self.isReplay = isReplay
        self.startedAt = startedAt
        self.durationMilliseconds = durationMilliseconds
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
    }
}

struct CapturedHeader: Codable, Hashable, Sendable {
    let name: String
    let value: String
}

/// Sends requests whose path starts with `pathPrefix` to another local port.
nonisolated struct TunnelRoute: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var pathPrefix: String
    var port: Int
    /// Removes the prefix before forwarding: `/api/users` reaches the target as `/users`.
    var stripsPrefix = false
    /// Off for noisy paths (health checks, polling) that shouldn't fill the inspector.
    var capturesRequests = true

    init(id: UUID = UUID(), pathPrefix: String, port: Int, stripsPrefix: Bool = false, capturesRequests: Bool = true) {
        self.id = id
        self.pathPrefix = pathPrefix
        self.port = port
        self.stripsPrefix = stripsPrefix
        self.capturesRequests = capturesRequests
    }

    /// Tolerates routes saved before newer fields existed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        pathPrefix = try container.decode(String.self, forKey: .pathPrefix)
        port = try container.decode(Int.self, forKey: .port)
        stripsPrefix = try container.decodeIfPresent(Bool.self, forKey: .stripsPrefix) ?? false
        capturesRequests = try container.decodeIfPresent(Bool.self, forKey: .capturesRequests) ?? true
    }

    /// Leading slash, no trailing slash (except for the root).
    static func normalizedPrefix(_ value: String) -> String {
        var prefix = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prefix.hasPrefix("/") { prefix = "/" + prefix }
        while prefix.count > 1 && prefix.hasSuffix("/") { prefix.removeLast() }
        return prefix
    }
}
