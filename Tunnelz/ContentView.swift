import SwiftUI
import SwiftData

struct ContentView: View {
    let processManager: TunnelProcessManager

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Tunnel.createdAt) private var tunnels: [Tunnel]
    @State private var selectedTunnelID: Tunnel.ID?
    @State private var selectedRequestID: CapturedRequest.ID?
    @State private var searchText = ""
    @State private var showsInspector = true
    @State private var showsAddTunnel = false
    @State private var tunnelBeingEdited: Tunnel?
    /// Plain-value snapshot of the visible rows, rebuilt only when requests or the search change.
    /// Feeding SwiftData models straight into the table made every scroll and render re-read them.
    @State private var filteredRequests: [RequestRow] = []
    @State private var sortOrder = [KeyPathComparator(\RequestRow.startedAt, order: .reverse)]
    @State private var methodFilter: Set<String> = []
    @State private var statusFilter: Set<StatusClass> = []
    @State private var showsSavedOnly = false

    private var hasActiveFilters: Bool {
        !methodFilter.isEmpty || !statusFilter.isEmpty || showsSavedOnly
    }

    private var selectedTunnel: Tunnel? { tunnels.first { $0.id == selectedTunnelID } }
    private var requests: [CapturedRequest] {
        guard let selectedTunnelID else { return [] }
        return processManager.requests(for: selectedTunnelID)
    }
    private var selectedRequest: CapturedRequest? { requests.first { $0.id == selectedRequestID } }
    private var selectedRuntime: TunnelRuntimeState {
        guard let selectedTunnel else { return TunnelRuntimeState() }
        return processManager.state(for: selectedTunnel.id)
    }
    private var selectedRequestIndex: Int? {
        guard let selectedRequestID else { return nil }
        return filteredRequests.firstIndex { $0.id == selectedRequestID }
    }
    private var canSelectPreviousRequest: Bool {
        guard let selectedRequestIndex else { return !filteredRequests.isEmpty }
        return selectedRequestIndex > filteredRequests.startIndex
    }
    private var canSelectNextRequest: Bool {
        guard let selectedRequestIndex else { return !filteredRequests.isEmpty }
        return selectedRequestIndex < filteredRequests.index(before: filteredRequests.endIndex)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                tunnels: tunnels,
                selection: $selectedTunnelID,
                processManager: processManager,
                onAddTunnel: { showsAddTunnel = true },
                onEditTunnel: { tunnelBeingEdited = $0 },
                onRemoveTunnel: removeTunnel
            )
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selectedTunnel?.name ?? "No Tunnel Selected").font(.headline)
                        if let tunnel = selectedTunnel {
                            if let publicURL = selectedRuntime.publicURL {
                                Text("\(publicURL.host() ?? publicURL.absoluteString) → \(tunnel.localURL)")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(runtimeDescription(for: selectedRuntime.phase))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    if let tunnel = selectedTunnel {
                        captureToggle(for: tunnel)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                Divider()
                Table(filteredRequests, selection: $selectedRequestID, sortOrder: $sortOrder) {
                    TableColumn("Method", value: \.method) { HTTPMethodBadge(method: $0.method) }.width(70)
                    TableColumn("Path", value: \.path) { request in
                        HStack(spacing: 6) {
                            if request.isSaved {
                                Image(systemName: "bookmark.fill")
                                    .foregroundStyle(.tint)
                                    .help("Saved request")
                            }
                            if request.isReplay {
                                Image(systemName: "arrow.clockwise")
                                    .help("Replayed request")
                            }
                            Text(request.path)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                        }
                    }
                    TableColumn("Status", value: \.status) { request in
                        Text(request.status, format: .number)
                            .foregroundStyle(request.status >= 400 ? .red : request.status >= 300 ? .yellow : .green)
                    }.width(62)
                    TableColumn("Duration", value: \.durationMilliseconds) { Text($0.duration) }.width(78)
                    TableColumn("Time", value: \.startedAt) { Text($0.time) }.width(78)
                }
            }
            .searchable(text: $searchText, prompt: "Search requests")
            .inspector(isPresented: $showsInspector) {
                RequestInspectorView(
                    request: selectedRequest,
                    tunnel: selectedTunnel,
                    publicURL: selectedRuntime.publicURL,
                    canReplay: selectedRuntime.phase == .running && selectedTunnel?.capturesRequests == true,
                    onReplay: processManager.replay,
                    onReplayEdited: processManager.replay,
                    onToggleSaved: { request in
                        request.isSaved.toggle()
                        try? modelContext.save()
                        rebuildRows()
                    }
                )
                    .inspectorColumnWidth(min: 400, ideal: 460, max: 560)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Previous Request", systemImage: "chevron.up") {
                    selectRequest(offset: -1)
                }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(!canSelectPreviousRequest)
                .help("Previous Request (↑)")

                Button("Next Request", systemImage: "chevron.down") {
                    selectRequest(offset: 1)
                }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(!canSelectNextRequest)
                .help("Next Request (↓)")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if let tunnel = selectedTunnel {
                    Button(tunnelActionTitle, systemImage: tunnelActionIcon) {
                        processManager.toggle(tunnel)
                    }
                    .disabled(selectedRuntime.phase == .stopping)

                    Button("Edit Tunnel", systemImage: "pencil") {
                        tunnelBeingEdited = tunnel
                    }
                    .help("Edit Tunnel")
                }
                Button("Clear All Requests", systemImage: "trash") {
                    guard let selectedTunnelID else { return }
                    deleteHistory(for: selectedTunnelID)
                    selectedRequestID = nil
                }
                Button("Toggle Inspector", systemImage: "sidebar.trailing") { showsInspector.toggle() }
                filterMenu
            }
        }
        .onAppear {
            selectedTunnelID = selectedTunnelID ?? tunnels.first?.id
        }
        .onChange(of: selectedTunnelID) {
            rebuildRows()
            selectedRequestID = requests.first?.id
        }
        // Compared by count and newest id: cheap, unlike comparing the model arrays.
        .onChange(of: RequestsVersion(count: requests.count, newestID: requests.first?.id), initial: true) {
            rebuildRows()
            if selectedRequestID == nil {
                selectedRequestID = requests.first?.id
            }
        }
        .onChange(of: searchText) { rebuildRows() }
        .onChange(of: sortOrder) { rebuildRows() }
        .onChange(of: methodFilter) { rebuildRows() }
        .onChange(of: statusFilter) { rebuildRows() }
        .onChange(of: showsSavedOnly) { rebuildRows() }
        .task {
            processManager.configurePersistence(modelContext)
            processManager.restoreTunnelsOnLaunch(tunnels)
        }
        .sheet(item: $tunnelBeingEdited) { tunnel in
            EditTunnelView(tunnel: tunnel) {
                try? modelContext.save()
                processManager.updateRouting(for: tunnel)
            }
        }
        .sheet(isPresented: $showsAddTunnel) {
            AddTunnelView { tunnel in
                modelContext.insert(tunnel)
                try? modelContext.save()
                selectedTunnelID = tunnel.id
                if tunnel.startsAutomatically {
                    processManager.start(tunnel)
                }
            }
        }
    }

    private func captureToggle(for tunnel: Tunnel) -> some View {
        let isCapturing = tunnel.capturesRequests
        return Button {
            tunnel.capturesRequests.toggle()
            try? modelContext.save()
            processManager.updateRouting(for: tunnel)
        } label: {
            Label(
                isCapturing ? "Capturing" : "Paused",
                systemImage: isCapturing ? "circle.fill" : "pause.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(isCapturing ? .green : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isCapturing ? "Pause capturing requests for this tunnel" : "Resume capturing requests for this tunnel")
    }

    private var tunnelActionTitle: String {
        switch selectedRuntime.phase {
        case .starting, .running: "Stop Tunnel"
        case .stopping: "Stopping Tunnel"
        case .stopped, .error: "Start Tunnel"
        }
    }

    private var tunnelActionIcon: String {
        switch selectedRuntime.phase {
        case .starting, .running: "stop.fill"
        case .stopping: "hourglass"
        case .stopped, .error: "play.fill"
        }
    }

    private func removeTunnel(_ tunnel: Tunnel) {
        processManager.stop(tunnel)
        deleteHistory(for: tunnel.id)
        if selectedTunnelID == tunnel.id {
            selectedTunnelID = tunnels.first { $0.id != tunnel.id }?.id
        }
        if tunnel.provider == .relay, let relayName = tunnel.relayName {
            let domain = tunnel.domain
            Task {
                // Free the address for reuse: drop any share still holding it, then the name.
                let relay = RelayManager()
                try? await relay.deleteStaleShares(name: relayName, domain: domain)
                try? await relay.releaseName(relayName)
            }
        }
        modelContext.delete(tunnel)
        try? modelContext.save()
    }

    private func deleteHistory(for tunnelID: UUID) {
        processManager.clearRequests(for: tunnelID)
    }

    private func rebuildRows() {
        var rows = requests.map(RequestRow.init)
        if !methodFilter.isEmpty {
            rows = rows.filter { methodFilter.contains($0.method.uppercased()) }
        }
        if !statusFilter.isEmpty {
            rows = rows.filter { statusFilter.contains(StatusClass(status: $0.status)) }
        }
        if showsSavedOnly {
            rows = rows.filter(\.isSaved)
        }
        if !searchText.isEmpty {
            rows = rows.filter {
                $0.method.localizedCaseInsensitiveContains(searchText)
                    || $0.fullPath.localizedCaseInsensitiveContains(searchText)
                    || String($0.status).contains(searchText)
            }
        }
        filteredRequests = rows.sorted(using: sortOrder)
    }

    private var filterMenu: some View {
        Menu {
            Section("Method") {
                ForEach(Self.filterableMethods, id: \.self) { method in
                    Toggle(method, isOn: membership(method, in: $methodFilter))
                }
            }
            Section("Status") {
                ForEach(StatusClass.allCases, id: \.self) { statusClass in
                    Toggle(statusClass.title, isOn: membership(statusClass, in: $statusFilter))
                }
            }
            Section {
                Toggle("Saved Only", systemImage: "bookmark", isOn: $showsSavedOnly)
            }
            if hasActiveFilters {
                Divider()
                Button("Clear Filters") {
                    methodFilter = []
                    statusFilter = []
                    showsSavedOnly = false
                }
            }
        } label: {
            Label(
                "Filter",
                systemImage: hasActiveFilters
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        .help("Filter requests")
    }

    private func membership<Value: Hashable>(_ value: Value, in set: Binding<Set<Value>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(value) },
            set: { isOn in
                if isOn { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) }
            }
        )
    }

    private static let filterableMethods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    private func selectRequest(offset: Int) {
        guard !filteredRequests.isEmpty else { return }

        guard let selectedRequestIndex else {
            selectedRequestID = filteredRequests.first?.id
            return
        }

        let targetIndex = selectedRequestIndex + offset
        guard filteredRequests.indices.contains(targetIndex) else { return }
        selectedRequestID = filteredRequests[targetIndex].id
    }

    private func runtimeDescription(for phase: TunnelRuntimePhase) -> String {
        switch phase {
        case .stopped: "Stopped · \(selectedTunnel?.localURL ?? "")"
        case .starting: "Starting Quick Tunnel…"
        case .running: "Running · \(selectedTunnel?.localURL ?? "")"
        case .stopping: "Stopping…"
        case .error: selectedRuntime.errorMessage ?? "Tunnel failed"
        }
    }
}

enum StatusClass: Int, CaseIterable, Hashable {
    case success = 2, redirect = 3, clientError = 4, serverError = 5, other = 0

    init(status: Int) {
        self = StatusClass(rawValue: status / 100) ?? .other
    }

    var title: String {
        switch self {
        case .success: "2xx Success"
        case .redirect: "3xx Redirect"
        case .clientError: "4xx Client Error"
        case .serverError: "5xx Server Error"
        case .other: "Other"
        }
    }
}

private struct RequestsVersion: Equatable {
    let count: Int
    let newestID: UUID?
}

/// What the requests table shows, copied out of a `CapturedRequest` once.
struct RequestRow: Identifiable, Hashable {
    let id: UUID
    let method: String
    let path: String
    let fullPath: String
    let status: Int
    let isReplay: Bool
    let isSaved: Bool
    let durationMilliseconds: Int
    let startedAt: Date
    let duration: String
    let time: String

    init(_ request: CapturedRequest) {
        id = request.id
        method = request.method
        path = request.pathWithoutQuery
        fullPath = request.path
        status = request.status
        isReplay = request.isReplay
        isSaved = request.isSaved
        durationMilliseconds = request.durationMilliseconds
        startedAt = request.startedAt
        duration = request.duration
        time = request.time
    }
}

#Preview {
    ContentView(processManager: TunnelProcessManager())
        .frame(width: 1_220, height: 760)
        .modelContainer(for: [Tunnel.self, CapturedRequest.self], inMemory: true)
}
