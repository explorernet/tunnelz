import Foundation
import Observation
import OSLog
import SwiftData
import Darwin

private let historyLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "tunnelz",
    category: "RequestHistory"
)

struct TunnelRuntimeState: Equatable {
    var phase: TunnelRuntimePhase = .stopped
    var publicURL: URL?
    var proxyPort: Int?
    var processID: Int32?
    var errorMessage: String?
}

@MainActor
@Observable
final class TunnelProcessManager {
    private(set) var states: [UUID: TunnelRuntimeState] = [:]
    private(set) var capturedRequests: [UUID: [CapturedRequest]] = [:]

    @ObservationIgnored private var modelContext: ModelContext?
    @ObservationIgnored private var didLoadHistory = false
    @ObservationIgnored private var processes: [UUID: Process] = [:]
    @ObservationIgnored private var adoptedProcessIDs: [UUID: Int32] = [:]
    @ObservationIgnored private var adoptedProcessSources: [UUID: DispatchSourceProcess] = [:]
    @ObservationIgnored private var proxies: [UUID: TunnelProxyServer] = [:]
    @ObservationIgnored private var outputPipes: [UUID: Pipe] = [:]
    @ObservationIgnored private var outputBuffers: [UUID: String] = [:]
    @ObservationIgnored private var relayURLs: [UUID: URL] = [:]
    @ObservationIgnored private var tunnelCache: [UUID: Tunnel] = [:]
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    func state(for tunnelID: UUID) -> TunnelRuntimeState {
        states[tunnelID] ?? TunnelRuntimeState()
    }

    @ObservationIgnored private var didRestoreTunnels = false

    /// Starts auto-start tunnels (and ones left running) once per app launch. Later calls
    /// are ignored, so reopening the menu bar or the window never restarts a tunnel the user stopped.
    func restoreTunnelsOnLaunch(_ tunnels: [Tunnel]) {
        guard !didRestoreTunnels else { return }
        didRestoreTunnels = true
        for tunnel in tunnels where tunnel.startsAutomatically || tunnel.runtimeProcessID != nil {
            start(tunnel)
        }
    }

    func configurePersistence(_ modelContext: ModelContext) {
        guard !didLoadHistory else { return }
        didLoadHistory = true
        self.modelContext = modelContext
        do {
            let descriptor = FetchDescriptor<CapturedRequest>(
                sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
            )
            let requests = try modelContext.fetch(descriptor)
            capturedRequests = Dictionary(grouping: requests.compactMap { request in
                request.tunnel.map { ($0.id, request) }
            }, by: \.0).mapValues { $0.map(\.1) }
            historyLogger.info("Loaded \(self.capturedRequests.values.reduce(0) { $0 + $1.count }) persisted requests")
        } catch {
            historyLogger.error("Could not load request history: \(error.localizedDescription, privacy: .public)")
        }
    }

    func requests(for tunnelID: UUID) -> [CapturedRequest] {
        capturedRequests[tunnelID, default: []]
    }

    func clearRequests(for tunnelID: UUID, keepingSaved: Bool = false) {
        guard let modelContext else { return }
        let all = capturedRequests[tunnelID, default: []]
        let kept = keepingSaved ? all.filter(\.isSaved) : []
        do {
            for request in all where !(keepingSaved && request.isSaved) {
                modelContext.delete(request)
            }
            if modelContext.hasChanges {
                try modelContext.save()
            }
            capturedRequests[tunnelID] = kept
        } catch {
            modelContext.rollback()
            historyLogger.error("Could not clear request history: \(error.localizedDescription, privacy: .public)")
        }
    }

    func deleteRequests(_ requests: [CapturedRequest]) {
        guard let modelContext, !requests.isEmpty else { return }
        let ids = Set(requests.map(\.id))
        do {
            requests.forEach(modelContext.delete)
            try modelContext.save()
            for (tunnelID, list) in capturedRequests {
                capturedRequests[tunnelID] = list.filter { !ids.contains($0.id) }
            }
        } catch {
            modelContext.rollback()
            historyLogger.error("Could not delete requests: \(error.localizedDescription, privacy: .public)")
        }
    }

    func replay(_ capturedRequest: CapturedRequest) {
        guard let tunnelID = capturedRequest.tunnel?.id else { return }
        replay(
            tunnelID: tunnelID,
            method: capturedRequest.method,
            path: capturedRequest.path,
            headers: capturedRequest.requestHeaders,
            body: capturedRequest.requestBody
        )
    }

    func replay(_ draft: ReplayRequestDraft) {
        replay(
            tunnelID: draft.tunnelID,
            method: draft.method,
            path: draft.path,
            headers: draft.headers,
            body: Data(draft.body.utf8)
        )
    }

    func start(_ tunnel: Tunnel) {
        guard processes[tunnel.id] == nil, adoptedProcessIDs[tunnel.id] == nil,
              states[tunnel.id]?.phase != .starting else { return }
        states[tunnel.id] = TunnelRuntimeState(phase: .starting)

        guard tunnel.runtimeProcessID != nil else {
            launchNew(tunnel)
            return
        }
        // Checking and stopping the old process can block, so it runs off the main thread.
        Task { [weak self] in
            guard let self, await !self.adoptPersistedProcess(for: tunnel),
                  self.states[tunnel.id]?.phase == .starting else { return }
            self.launchNew(tunnel)
        }
    }

    private func launchNew(_ tunnel: Tunnel) {
        let tunnelID = tunnel.id
        let executable: String
        switch tunnel.provider {
        case .quick:
            guard let path = cloudflaredExecutable else {
                states[tunnel.id] = TunnelRuntimeState(
                    phase: .error,
                    errorMessage: "cloudflared is not installed."
                )
                return
            }
            executable = path
        case .relay:
            guard let path = RelayManager.executablePath else {
                states[tunnel.id] = TunnelRuntimeState(
                    phase: .error,
                    errorMessage: "The relay client is not installed. Install it in Settings → Relay."
                )
                return
            }
            guard tunnel.relayURL != nil, RelayManager.isConnected(domain: tunnel.domain) else {
                states[tunnel.id] = TunnelRuntimeState(
                    phase: .error,
                    errorMessage: "This Mac is not connected to the relay. Connect it in Settings → Relay."
                )
                return
            }
            executable = path
        }

        let proxy = TunnelProxyServer(tunnelID: tunnelID, defaultPort: tunnel.localPort, routes: tunnel.routes, capturesRequests: tunnel.capturesRequests) { [weak self] request in
            Task { @MainActor [weak self] in
                self?.record(request)
            }
        }
        let proxyPort: Int
        do {
            proxyPort = try proxy.start()
            proxies[tunnelID] = proxy
            states[tunnelID]?.proxyPort = proxyPort
        } catch {
            states[tunnelID] = TunnelRuntimeState(
                phase: .error,
                errorMessage: "Could not start Tunnelz: \(error.localizedDescription)"
            )
            return
        }

        switch tunnel.provider {
        case .quick:
            launch(
                tunnel,
                executable: executable,
                arguments: ["tunnel", "--url", "http://127.0.0.1:\(proxyPort)"],
                proxyPort: proxyPort
            )
        case .relay:
            guard let relayName = tunnel.relayName, let relayURL = tunnel.relayURL else { return }
            relayURLs[tunnelID] = relayURL
            let domain = tunnel.domain
            Task { [weak self] in
                // A share left behind by a crash keeps the name busy; clear it first.
                try? await RelayManager().deleteStaleShares(name: relayName, domain: domain)
                guard let self, self.states[tunnelID]?.phase == .starting else { return }
                self.launch(
                    tunnel,
                    executable: executable,
                    arguments: [
                        "share", "public", "http://127.0.0.1:\(proxyPort)",
                        "-n", "public:\(relayName)", "--headless"
                    ],
                    proxyPort: proxyPort
                )
            }
        }
    }

    private func launch(_ tunnel: Tunnel, executable: String, arguments: [String], proxyPort: Int) {
        let tunnelID = tunnel.id
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        outputBuffers[tunnelID] = ""

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                self?.consume(text, for: tunnelID)
            }
        }

        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.processDidTerminate(id: tunnelID, exitCode: process.terminationStatus)
            }
        }

        do {
            try process.run()
            processes[tunnelID] = process
            outputPipes[tunnelID] = pipe
            states[tunnelID]?.processID = process.processIdentifier
            persistRuntime(
                for: tunnel,
                processID: process.processIdentifier,
                proxyPort: proxyPort,
                publicURL: nil,
                executablePath: executable
            )
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            stopProxy(id: tunnelID)
            states[tunnelID] = TunnelRuntimeState(
                phase: .error,
                errorMessage: error.localizedDescription
            )
        }
    }

    func stop(_ tunnel: Tunnel) {
        if let process = processes[tunnel.id] {
            states[tunnel.id]?.phase = .stopping
            if process.isRunning {
                process.terminate()
            }
            return
        }

        if let processID = adoptedProcessIDs[tunnel.id] {
            states[tunnel.id]?.phase = .stopping
            if kill(processID, SIGTERM) != 0 && errno == ESRCH {
                processDidTerminate(id: tunnel.id, exitCode: 0)
            }
            return
        }

        stopProxy(id: tunnel.id)
        relayURLs[tunnel.id] = nil
        states[tunnel.id] = TunnelRuntimeState(phase: .stopped)
        clearPersistedRuntime(for: tunnel.id)
    }

    /// Applies configuration changes (e.g. a new local port) to a running tunnel.
    /// Points a running tunnel at its current port and routes; takes effect on the next request.
    func updateRouting(for tunnel: Tunnel) {
        proxies[tunnel.id]?.updateRouting(defaultPort: tunnel.localPort, routes: tunnel.routes, capturesRequests: tunnel.capturesRequests)
    }

    func toggle(_ tunnel: Tunnel) {
        switch state(for: tunnel.id).phase {
        case .starting, .running:
            stop(tunnel)
        case .stopped, .error:
            start(tunnel)
        case .stopping:
            break
        }
    }

    func stopAll() {
        for (id, process) in processes {
            states[id]?.phase = .stopping
            if process.isRunning {
                process.terminate()
            }
        }
        for (id, processID) in adoptedProcessIDs {
            states[id]?.phase = .stopping
            kill(processID, SIGTERM)
        }
    }

    func shutdownForApplicationTermination() {
        let processIDs = Set(
            processes.values.map(\.processIdentifier) + Array(adoptedProcessIDs.values)
        )

        for pipe in outputPipes.values {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        for process in processes.values {
            process.terminationHandler = nil
        }
        for source in adoptedProcessSources.values {
            source.cancel()
        }

        for processID in processIDs {
            _ = Self.terminateProcess(processID)
        }
        for proxy in proxies.values {
            proxy.stop()
        }

        pendingSave?.cancel()
        pendingSave = nil
        clearAllPersistedRuntimes()
        processes.removeAll()
        adoptedProcessIDs.removeAll()
        adoptedProcessSources.removeAll()
        proxies.removeAll()
        outputPipes.removeAll()
        outputBuffers.removeAll()
        relayURLs.removeAll()
        states.removeAll()
    }

    private func consume(_ text: String, for tunnelID: UUID) {
        guard processes[tunnelID] != nil else { return }
        outputBuffers[tunnelID, default: ""].append(text)

        if let relayURL = relayURLs[tunnelID] {
            if outputBuffers[tunnelID, default: ""].contains("access your zrok share"),
               states[tunnelID]?.phase == .starting {
                states[tunnelID]?.publicURL = relayURL
                states[tunnelID]?.phase = .running
                states[tunnelID]?.errorMessage = nil
                persistPublicURL(relayURL, for: tunnelID)
            }
        } else if let match = outputBuffers[tunnelID]?.range(
            of: #"https://[a-zA-Z0-9-]+\.trycloudflare\.com"#,
            options: .regularExpression
        ), let value = outputBuffers[tunnelID].map({ String($0[match]) }), let url = URL(string: value) {
            states[tunnelID]?.publicURL = url
            states[tunnelID]?.phase = .running
            states[tunnelID]?.errorMessage = nil
            persistPublicURL(url, for: tunnelID)
        }

        if outputBuffers[tunnelID, default: ""].count > 16_000 {
            outputBuffers[tunnelID] = String(outputBuffers[tunnelID, default: ""].suffix(8_000))
        }
    }

    private func processDidTerminate(id: UUID, exitCode: Int32) {
        outputPipes[id]?.fileHandleForReading.readabilityHandler = nil
        outputPipes[id] = nil
        processes[id] = nil
        adoptedProcessSources[id]?.cancel()
        adoptedProcessSources[id] = nil
        adoptedProcessIDs[id] = nil
        stopProxy(id: id)
        clearPersistedRuntime(for: id)

        let wasStopping = states[id]?.phase == .stopping
        if wasStopping || exitCode == 0 {
            states[id] = TunnelRuntimeState(phase: .stopped)
        } else {
            var output = outputBuffers[id, default: ""]
            if relayURLs[id] != nil {
                output = RelayManager.cleanError(output)
            }
            states[id] = TunnelRuntimeState(
                phase: .error,
                errorMessage: output.isEmpty
                    ? "The tunnel exited with code \(exitCode)."
                    : String(output.suffix(1_500))
            )
        }
        outputBuffers[id] = nil
        relayURLs[id] = nil
    }

    private func record(_ exchange: CapturedExchange) {
        guard let modelContext else {
            historyLogger.error("Captured request before persistence was configured")
            return
        }

        guard let tunnel = persistedTunnel(id: exchange.tunnelID) else {
            historyLogger.error("Could not find tunnel for captured request")
            return
        }

        let capturedRequest = CapturedRequest(exchange: exchange, tunnel: tunnel)
        modelContext.insert(capturedRequest)
        var requests = capturedRequests[exchange.tunnelID, default: []]
        requests.insert(capturedRequest, at: 0)
        let limit = AppSettings.requestHistoryLimit
        if requests.count > limit {
            // Drop the oldest unsaved requests; saved ones stay until removed by hand.
            var unsavedKept = 0
            requests.removeAll { request in
                guard !request.isSaved else { return false }
                unsavedKept += 1
                guard unsavedKept > limit else { return false }
                modelContext.delete(request)
                return true
            }
        }
        capturedRequests[exchange.tunnelID] = requests
        scheduleHistorySave()
    }

    /// Bursts of requests (a page load can make dozens) are written to disk together.
    private func scheduleHistorySave() {
        guard pendingSave == nil else { return }
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            self.pendingSave = nil
            self.savePersistence()
        }
    }

    private func stopProxy(id: UUID) {
        proxies[id]?.stop()
        proxies[id] = nil
    }

    private func adoptPersistedProcess(for tunnel: Tunnel) async -> Bool {
        guard let storedPID = tunnel.runtimeProcessID,
              let processID = Int32(exactly: storedPID),
              let proxyPort = tunnel.runtimeProxyPort,
              let executablePath = tunnel.runtimeExecutablePath else {
            clearPersistedRuntime(for: tunnel.id)
            return false
        }

        let isExpected = await Task.detached {
            Self.isExpectedTunnelProcess(processID: processID, executablePath: executablePath, proxyPort: proxyPort)
        }.value
        guard isExpected else {
            clearPersistedRuntime(for: tunnel.id)
            return false
        }
        // Stopped by the user while the check ran.
        guard states[tunnel.id]?.phase == .starting else { return true }

        guard let publicURLString = tunnel.runtimePublicURL,
              let publicURL = URL(string: publicURLString) else {
            guard await Task.detached(operation: { Self.terminateProcess(processID) }).value else {
                states[tunnel.id] = TunnelRuntimeState(
                    phase: .error,
                    errorMessage: "Could not stop the previous tunnel process."
                )
                return true
            }
            clearPersistedRuntime(for: tunnel.id)
            return false
        }

        let proxy = TunnelProxyServer(tunnelID: tunnel.id, defaultPort: tunnel.localPort, routes: tunnel.routes, capturesRequests: tunnel.capturesRequests) { [weak self] request in
            Task { @MainActor [weak self] in
                self?.record(request)
            }
        }

        do {
            _ = try proxy.start(port: proxyPort)
        } catch {
            guard await Task.detached(operation: { Self.terminateProcess(processID) }).value else {
                states[tunnel.id] = TunnelRuntimeState(
                    phase: .error,
                    errorMessage: "Could not restore the Tunnelz proxy or stop the previous tunnel process."
                )
                return true
            }
            clearPersistedRuntime(for: tunnel.id)
            return false
        }

        proxies[tunnel.id] = proxy
        adoptedProcessIDs[tunnel.id] = processID
        if let relayURL = tunnel.relayURL {
            relayURLs[tunnel.id] = relayURL
        }
        states[tunnel.id] = TunnelRuntimeState(
            phase: .running,
            publicURL: publicURL,
            proxyPort: proxyPort,
            processID: processID
        )
        monitorAdoptedProcess(processID, tunnelID: tunnel.id)
        return true
    }

    private func monitorAdoptedProcess(_ processID: Int32, tunnelID: UUID) {
        let source = DispatchSource.makeProcessSource(
            identifier: pid_t(processID),
            eventMask: .exit,
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.processDidTerminate(id: tunnelID, exitCode: 0)
            }
        }
        adoptedProcessSources[tunnelID] = source
        source.resume()
    }

    nonisolated private static func isExpectedTunnelProcess(
        processID: Int32,
        executablePath: String,
        proxyPort: Int
    ) -> Bool {
        guard kill(processID, 0) == 0 else { return false }

        var pathBuffer = [CChar](repeating: 0, count: 4_096)
        let pathLength = proc_pidpath(processID, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return false }
        let runningExecutable = String(cString: pathBuffer)
        let expectedExecutable = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
        let resolvedRunningExecutable = URL(fileURLWithPath: runningExecutable).resolvingSymlinksInPath().path
        guard resolvedRunningExecutable == expectedExecutable else { return false }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(processID), "-o", "command="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        guard process.terminationStatus == 0 else { return false }
        let command = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        // The executable path was already matched; the proxy port ties it to this tunnel.
        return command.contains("http://127.0.0.1:\(proxyPort)")
    }

    nonisolated private static func terminateProcess(_ processID: Int32) -> Bool {
        if kill(processID, SIGTERM) != 0 {
            return errno == ESRCH
        }

        for _ in 0..<20 {
            if kill(processID, 0) != 0 && errno == ESRCH {
                return true
            }
            usleep(50_000)
        }

        if kill(processID, SIGKILL) != 0 {
            return errno == ESRCH
        }

        for _ in 0..<20 {
            if kill(processID, 0) != 0 && errno == ESRCH {
                return true
            }
            usleep(50_000)
        }
        return false
    }

    private func persistRuntime(
        for tunnel: Tunnel,
        processID: Int32,
        proxyPort: Int,
        publicURL: URL?,
        executablePath: String
    ) {
        tunnel.runtimeProcessID = Int(processID)
        tunnel.runtimeProxyPort = proxyPort
        tunnel.runtimePublicURL = publicURL?.absoluteString
        tunnel.runtimeExecutablePath = executablePath
        savePersistence()
    }

    private func persistPublicURL(_ url: URL, for tunnelID: UUID) {
        guard let tunnel = persistedTunnel(id: tunnelID) else { return }
        tunnel.runtimePublicURL = url.absoluteString
        savePersistence()
    }

    private func clearPersistedRuntime(for tunnelID: UUID) {
        guard let tunnel = persistedTunnel(id: tunnelID) else { return }
        tunnel.runtimeProcessID = nil
        tunnel.runtimeProxyPort = nil
        tunnel.runtimePublicURL = nil
        tunnel.runtimeExecutablePath = nil
        savePersistence()
    }

    private func clearAllPersistedRuntimes() {
        guard let modelContext,
              let tunnels = try? modelContext.fetch(FetchDescriptor<Tunnel>()) else {
            return
        }
        for tunnel in tunnels {
            tunnel.runtimeProcessID = nil
            tunnel.runtimeProxyPort = nil
            tunnel.runtimePublicURL = nil
            tunnel.runtimeExecutablePath = nil
        }
        savePersistence()
    }

    private func persistedTunnel(id: UUID) -> Tunnel? {
        if let cached = tunnelCache[id], !cached.isDeleted, cached.modelContext != nil {
            return cached
        }
        guard let modelContext else { return nil }
        let descriptor = FetchDescriptor<Tunnel>(predicate: #Predicate { $0.id == id })
        let tunnel = try? modelContext.fetch(descriptor).first
        tunnelCache[id] = tunnel
        return tunnel
    }

    private func savePersistence() {
        guard let modelContext, modelContext.hasChanges else { return }
        do {
            try modelContext.save()
        } catch {
            historyLogger.error("Could not save tunnel runtime: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func replay(
        tunnelID: UUID,
        method: String,
        path: String,
        headers: [CapturedHeader],
        body: Data
    ) {
        guard let proxyPort = states[tunnelID]?.proxyPort,
              let url = URL(string: "http://127.0.0.1:\(proxyPort)\(path)") else {
            return
        }

        let normalizedMethod = method.uppercased()
        var request = URLRequest(url: url)
        request.httpMethod = normalizedMethod
        if !body.isEmpty && normalizedMethod != "GET" && normalizedMethod != "HEAD" {
            request.httpBody = body
        }
        for header in headers {
            guard !Self.headersRemovedBeforeReplay.contains(header.name.lowercased()) else { continue }
            request.addValue(header.value, forHTTPHeaderField: header.name)
        }
        request.setValue("1", forHTTPHeaderField: "x-inspector-replay")
        ProxySession.shared.dataTask(with: request).resume()
    }

    private var cloudflaredExecutable: String? {
        ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static let headersRemovedBeforeReplay: Set<String> = [
        "connection", "content-length", "host", "keep-alive", "proxy-authenticate",
        "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade",
        "x-inspector-replay"
    ]
}
