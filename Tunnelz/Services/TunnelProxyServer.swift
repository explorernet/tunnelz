import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

final class TunnelProxyServer {
    /// Shared by every tunnel: one thread per core instead of one per tunnel.
    private let group = MultiThreadedEventLoopGroup.singleton
    private let tunnelID: UUID
    private let router: ProxyRouter
    private let onCapture: (CapturedExchange) -> Void
    private var channel: Channel?

    init(
        tunnelID: UUID,
        defaultPort: Int,
        routes: [TunnelRoute],
        capturesRequests: Bool,
        onCapture: @escaping (CapturedExchange) -> Void
    ) {
        self.tunnelID = tunnelID
        router = ProxyRouter(defaultPort: defaultPort, routes: routes, capturesRequests: capturesRequests)
        self.onCapture = onCapture
    }

    /// Applies new routing to requests from now on, without restarting the tunnel.
    func updateRouting(defaultPort: Int, routes: [TunnelRoute], capturesRequests: Bool) {
        router.update(defaultPort: defaultPort, routes: routes, capturesRequests: capturesRequests)
    }

    func start(port requestedPort: Int = 0) throws -> Int {
        let tunnelID = tunnelID
        let router = router
        let onCapture = onCapture
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // Handlers are named so a WebSocket upgrade can strip the HTTP codec
                // and turn the connection into a raw pipe to the origin.
                channel.eventLoop.makeCompletedFuture {
                    let sync = channel.pipeline.syncOperations
                    try sync.addHandler(HTTPResponseEncoder(), name: InspectingHTTPHandler.encoderName)
                    try sync.addHandler(
                        ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                        name: InspectingHTTPHandler.decoderName
                    )
                    try sync.addHandler(
                        InspectingHTTPHandler(tunnelID: tunnelID, router: router, onCapture: onCapture),
                        name: InspectingHTTPHandler.handlerName
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try bootstrap.bind(host: "127.0.0.1", port: requestedPort).wait()
        guard let port = channel.localAddress?.port else {
            try channel.close().wait()
            throw ProxyError.missingLocalPort
        }
        self.channel = channel
        return port
    }

    func stop() {
        channel?.close(promise: nil)
        channel = nil
    }

    enum ProxyError: LocalizedError {
        case missingLocalPort

        var errorDescription: String? {
            "The inspector proxy could not allocate a local port."
        }
    }
}

private final class InspectingHTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    static let encoderName = "http-encoder"
    static let decoderName = "http-decoder"
    static let handlerName = "inspector"

    private let tunnelID: UUID
    private let router: ProxyRouter
    private let onCapture: (CapturedExchange) -> Void
    private var requestHead: HTTPRequestHead?
    private var requestBody = Data()
    private var startedAt = Date()
    private var bodyLimit = 0
    private var isRejectingBody = false
    /// The origin request in flight, paused while the client can't keep up.
    private var activeTask: URLSessionDataTask?
    private var isTaskSuspended = false

    init(tunnelID: UUID, router: ProxyRouter, onCapture: @escaping (CapturedExchange) -> Void) {
        self.tunnelID = tunnelID
        self.router = router
        self.onCapture = onCapture
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head
            requestBody.removeAll(keepingCapacity: true)
            startedAt = .now
            isRejectingBody = false
            bodyLimit = AppSettings.maxRequestBodyBytes
            // The decoder stops parsing after an upgrade head, so `.end` may never come.
            if Self.isWebSocketUpgrade(head) {
                upgradeToWebSocket(context: context, head: head)
            } else if let length = head.headers.first(name: "content-length").flatMap(Int.init), length > bodyLimit {
                rejectTooLarge(context: context)
            }
        case .body(var buffer):
            guard !isRejectingBody else { return }
            // The tunnel is public, so an unbounded upload could exhaust memory.
            guard requestBody.count + buffer.readableBytes <= bodyLimit else {
                rejectTooLarge(context: context)
                return
            }
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                requestBody.append(contentsOf: bytes)
            }
        case .end:
            guard !isRejectingBody, let head = requestHead, !Self.isWebSocketUpgrade(head) else { return }
            forwardRequest(context: context, head: head)
        }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable, isTaskSuspended {
            isTaskSuspended = false
            activeTask?.resume()
        }
        context.fireChannelWritabilityChanged()
    }

    private func rejectTooLarge(context: ChannelHandlerContext) {
        isRejectingBody = true
        requestBody.removeAll()
        sendError(
            context: context,
            status: .payloadTooLarge,
            message: "Request body exceeds the \(bodyLimit / 1_048_576) MB limit set in Tunnelz."
        )
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    // MARK: - HTTP (streamed, so SSE and large bodies flow as they arrive)

    private func forwardRequest(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let target = router.target(for: head.uri)
        guard let url = URL(string: "http://127.0.0.1:\(target.port)\(target.uri)") else {
            sendError(context: context, status: .badGateway, message: "Invalid request URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = head.method.rawValue
        request.httpBody = requestBody.isEmpty ? nil : requestBody
        for header in head.headers where !Self.headersRemovedBeforeForwarding.contains(header.name.lowercased()) {
            request.addValue(header.value, forHTTPHeaderField: header.name)
        }
        request.setValue("127.0.0.1:\(target.port)", forHTTPHeaderField: "Host")

        let tunnelID = tunnelID
        let startedAt = startedAt
        let captureLimit = AppSettings.maxCapturedBodyBytes
        let capturedRequestBody = Data(requestBody.prefix(captureLimit))
        let isReplay = head.headers.first(name: Self.replayHeader) != nil
        let requestHeaders = head.headers
            .filter { $0.name.lowercased() != Self.replayHeader }
            .map { CapturedHeader(name: $0.name, value: $0.value) }
        let method = head.method.rawValue
        let path = head.uri
        let onCapture = onCapture
        let eventLoop = context.eventLoop

        var status = 502
        var responseHeaders: [CapturedHeader] = []
        var capturedResponseBody = Data()
        var didSendHead = false

        let delegate = StreamingResponseDelegate(
            onResponse: { response in
                status = response.statusCode
                responseHeaders = response.allHeaderFields.compactMap { key, value in
                    guard let name = key as? String else { return nil }
                    return CapturedHeader(name: name, value: String(describing: value))
                }
                let headersToSend = responseHeaders
                eventLoop.execute {
                    var headers = HTTPHeaders()
                    // URLSession already decompressed the body, and it is re-sent chunked.
                    for header in headersToSend where !Self.headersRemovedFromResponse.contains(header.name.lowercased()) {
                        if header.name.lowercased() == "set-cookie" {
                            // URLSession joins repeated Set-Cookie headers with commas; browsers need them separate.
                            for cookie in Self.splitSetCookie(header.value) {
                                headers.add(name: header.name, value: cookie)
                            }
                        } else {
                            headers.add(name: header.name, value: header.value)
                        }
                    }
                    headers.replaceOrAdd(name: "connection", value: "close")
                    let responseHead = HTTPResponseHead(
                        version: head.version,
                        status: HTTPResponseStatus(statusCode: status),
                        headers: headers
                    )
                    didSendHead = true
                    context.writeAndFlush(self.wrapOutboundOut(.head(responseHead)), promise: nil)
                }
            },
            onData: { data in
                if target.capturesRequests, capturedResponseBody.count < captureLimit {
                    capturedResponseBody.append(data.prefix(captureLimit - capturedResponseBody.count))
                }
                eventLoop.execute {
                    var buffer = context.channel.allocator.buffer(capacity: data.count)
                    buffer.writeBytes(data)
                    context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    // A slow client: pause the origin until the socket drains (see channelWritabilityChanged).
                    if !context.channel.isWritable, !self.isTaskSuspended, let task = self.activeTask {
                        self.isTaskSuspended = true
                        task.suspend()
                    }
                }
            },
            onComplete: { error in
                let elapsed = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
                if target.capturesRequests { onCapture(CapturedExchange(
                    tunnelID: tunnelID,
                    method: method,
                    path: path,
                    status: status,
                    isReplay: isReplay,
                    startedAt: startedAt,
                    durationMilliseconds: elapsed,
                    requestHeaders: AppSettings.headersForCapture(requestHeaders),
                    requestBody: capturedRequestBody,
                    responseHeaders: AppSettings.headersForCapture(responseHeaders),
                    responseBody: capturedResponseBody
                )) }

                eventLoop.execute {
                    self.activeTask = nil
                    self.isTaskSuspended = false
                    guard didSendHead else {
                        self.sendError(context: context, status: .badGateway, message: error?.localizedDescription ?? "No response")
                        return
                    }
                    context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { _ in
                        context.close(promise: nil)
                    }
                }
            }
        )

        let task = ProxySession.shared.dataTask(with: request)
        task.delegate = delegate
        activeTask = task
        isTaskSuspended = false
        task.resume()

        // Stop the origin request if the client goes away (e.g. a closed SSE tab).
        context.channel.closeFuture.whenComplete { _ in task.cancel() }
    }

    // MARK: - WebSocket (raw pipe after the handshake)

    private func upgradeToWebSocket(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let serverChannel = context.channel
        let pipeline = context.pipeline
        let (serverGlue, originGlue) = GlueHandler.matchedPair()

        let target = router.target(for: head.uri)
        var rawHead = "\(head.method.rawValue) \(target.uri) HTTP/1.1\r\n"
        for header in head.headers where header.name.lowercased() != "host" && header.name.lowercased() != Self.replayHeader {
            rawHead += "\(header.name): \(header.value)\r\n"
        }
        rawHead += "Host: 127.0.0.1:\(target.port)\r\n\r\n"

        if target.capturesRequests { onCapture(CapturedExchange(
            tunnelID: tunnelID,
            method: head.method.rawValue,
            path: head.uri,
            status: 101,
            isReplay: false,
            startedAt: startedAt,
            durationMilliseconds: 0,
            requestHeaders: AppSettings.headersForCapture(head.headers.map { CapturedHeader(name: $0.name, value: $0.value) }),
            requestBody: Data(),
            responseHeaders: [],
            responseBody: Data()
        )) }

        ClientBootstrap(group: context.eventLoop)
            .channelInitializer { $0.pipeline.addHandler(originGlue) }
            .connect(host: "127.0.0.1", port: target.port)
            .flatMap { originChannel -> EventLoopFuture<Void> in
                var buffer = originChannel.allocator.buffer(capacity: rawHead.utf8.count)
                buffer.writeString(rawHead)
                originChannel.writeAndFlush(buffer, promise: nil)
                // The decoder goes last so any bytes it already buffered reach the glue.
                return pipeline.addHandler(serverGlue)
                    .flatMap { pipeline.removeHandler(name: Self.handlerName) }
                    .flatMap { pipeline.removeHandler(name: Self.encoderName) }
                    .flatMap { pipeline.removeHandler(name: Self.decoderName) }
            }
            .whenFailure { _ in
                serverChannel.close(promise: nil)
            }
    }

    /// Splits on commas that start a new `name=value`, leaving the comma in `Expires=Wed, 21 Oct…` alone.
    static func splitSetCookie(_ value: String) -> [String] {
        value
            .replacing(/,\s*(?=[^;,\s]+=)/, with: "\u{0}")
            .split(separator: "\u{0}")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isWebSocketUpgrade(_ head: HTTPRequestHead) -> Bool {
        head.headers[canonicalForm: "upgrade"].contains { $0.lowercased() == "websocket" }
    }

    // MARK: - Helpers

    private func sendError(context: ChannelHandlerContext, status: HTTPResponseStatus, message: String) {
        let data = Data(message.utf8)
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "text/plain; charset=utf-8")
        headers.add(name: "content-length", value: String(data.count))
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }

    private static let hopByHopHeaders: Set<String> = [
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailer", "transfer-encoding", "upgrade"
    ]
    private static let replayHeader = "x-inspector-replay"
    private static let headersRemovedBeforeForwarding = hopByHopHeaders.union([replayHeader])
    private static let headersRemovedFromResponse = hopByHopHeaders.union(["content-encoding", "content-length"])
}

/// No cache, cookies or redirects: the proxy (and replays) must pass responses through untouched.
nonisolated enum ProxySession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 24 * 60 * 60
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        configuration.httpMaximumConnectionsPerHost = 64
        return URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()
}

nonisolated private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Delivers a response piece by piece instead of buffering it.
nonisolated private final class StreamingResponseDelegate: NSObject, URLSessionDataDelegate {
    private let onResponse: (HTTPURLResponse) -> Void
    private let onData: (Data) -> Void
    private let onComplete: (Error?) -> Void

    init(
        onResponse: @escaping (HTTPURLResponse) -> Void,
        onData: @escaping (Data) -> Void,
        onComplete: @escaping (Error?) -> Void
    ) {
        self.onResponse = onResponse
        self.onData = onData
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let response = response as? HTTPURLResponse {
            onResponse(response)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        onData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onComplete(error)
    }

    /// Redirects go back to the browser as-is.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Joins two channels so bytes read from one are written to the other.
nonisolated private final class GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    /// A read held back until the partner can take more bytes.
    private var hasPendingRead = false

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        // The partner may have deferred a read while this side was not yet in a pipeline.
        partner?.partnerWritabilityChanged(isWritable: context.channel.isWritable)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.context?.write(data, promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.context?.flush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.context?.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        partner?.partnerWritabilityChanged(isWritable: context.channel.isWritable)
        context.fireChannelWritabilityChanged()
    }

    /// Only reads when the partner can write, so a slow side never makes bytes pile up in memory.
    func read(context: ChannelHandlerContext) {
        if partner?.context?.channel.isWritable == true {
            context.read()
        } else {
            hasPendingRead = true
        }
    }

    private func partnerWritabilityChanged(isWritable: Bool) {
        guard isWritable, hasPendingRead, let context else { return }
        hasPendingRead = false
        context.read()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// Picks the local port for each request: the longest matching route prefix, else the default port.
/// Read from NIO threads and updated from the main actor.
nonisolated final class ProxyRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var defaultPort: Int
    private var routes: [TunnelRoute]
    private var capturesRequests: Bool

    init(defaultPort: Int, routes: [TunnelRoute], capturesRequests: Bool) {
        self.defaultPort = defaultPort
        self.routes = Self.sorted(routes)
        self.capturesRequests = capturesRequests
    }

    func update(defaultPort: Int, routes: [TunnelRoute], capturesRequests: Bool) {
        lock.withLock {
            self.defaultPort = defaultPort
            self.routes = Self.sorted(routes)
            self.capturesRequests = capturesRequests
        }
    }

    /// Where a request goes, and whether it is recorded: both the tunnel and its route must allow it.
    func target(for uri: String) -> (port: Int, uri: String, capturesRequests: Bool) {
        let (defaultPort, routes, tunnelCaptures) = lock.withLock {
            (self.defaultPort, self.routes, self.capturesRequests)
        }
        let pathEnd = uri.firstIndex { $0 == "?" || $0 == "#" } ?? uri.endIndex
        let path = uri[..<pathEnd]

        for route in routes {
            let prefix = route.pathPrefix
            let matches = prefix == "/"
                || path == prefix
                || path.hasPrefix(prefix + "/")
            guard matches else { continue }
            let captures = tunnelCaptures && route.capturesRequests
            guard route.stripsPrefix, prefix != "/" else { return (route.port, uri, captures) }

            let remainder = String(uri.dropFirst(prefix.count))
            return (route.port, remainder.hasPrefix("/") ? remainder : "/" + remainder, captures)
        }
        return (defaultPort, uri, tunnelCaptures)
    }

    private static func sorted(_ routes: [TunnelRoute]) -> [TunnelRoute] {
        routes.sorted { $0.pathPrefix.count > $1.pathPrefix.count }
    }
}
