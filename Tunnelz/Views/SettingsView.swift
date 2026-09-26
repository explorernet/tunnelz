import SwiftUI

struct SettingsView: View {
    private enum Pane: Hashable { case general, relay, cloudflare, users }
    @State private var selection: Pane = .general
    @AppStorage(RelayManager.adminTokenKey) private var adminToken = ""

    var body: some View {
        // Same structure as System Settings: fixed sidebar, grouped form on the right.
        NavigationSplitView {
            List(selection: $selection) {
                paneLabel("General", systemImage: "gearshape.fill", color: .gray)
                    .tag(Pane.general)
                paneLabel("Relay", systemImage: "point.3.connected.trianglepath.dotted", color: .purple)
                    .tag(Pane.relay)
                paneLabel("Cloudflare", systemImage: "cloud.fill", color: .orange)
                    .tag(Pane.cloudflare)
                if !adminToken.isEmpty {
                    paneLabel("Users", systemImage: "person.2.fill", color: .indigo)
                        .tag(Pane.users)
                }
            }
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(200)
        } detail: {
            Group {
                switch selection {
                case .general:
                    GeneralSettingsView()
                case .cloudflare:
                    CloudflaredSettingsView()
                case .users where !adminToken.isEmpty:
                    RelayUsersView()
                default:
                    RelaySettingsView()
                }
            }
            .navigationTitle(title)
        }
        .frame(minWidth: 720, minHeight: 500)
        .onChange(of: adminToken) {
            if adminToken.isEmpty && selection == .users { selection = .relay }
        }
    }

    private var title: String {
        switch selection {
        case .general: "General"
        case .relay: "Relay"
        case .users: "Users"
        case .cloudflare: "Cloudflare"
        }
    }

    private func paneLabel(_ title: String, systemImage: String, color: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(AppSettings.maxRequestBodyMBKey) private var maxRequestBodyMB = AppSettings.defaultMaxRequestBodyMB
    @AppStorage(AppSettings.maxCapturedBodyKBKey) private var maxCapturedBodyKB = AppSettings.defaultMaxCapturedBodyKB
    @AppStorage(AppSettings.requestHistoryLimitKey) private var requestHistoryLimit = AppSettings.defaultRequestHistoryLimit
    @AppStorage(AppSettings.redactsSensitiveHeadersKey) private var redactsSensitiveHeaders = AppSettings.defaultRedactsSensitiveHeaders
    @State private var updater = AppUpdater.shared

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Version") {
                    HStack(spacing: 10) {
                        Text(version)
                        if updater.isAvailable {
                            Button("Check for Updates…") { updater.checkForUpdates() }
                        }
                    }
                }
                if updater.isAvailable {
                    Toggle("Check for Updates Automatically", isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.automaticallyChecksForUpdates = $0 }
                    ))
                }
            } header: {
                Text("Tunnelz")
            } footer: {
                if !updater.isAvailable {
                    Text("Updates are available in release builds.")
                }
            }

            Section {
                Picker("Maximum Request Size", selection: $maxRequestBodyMB) {
                    ForEach([10, 50, 100, 500, 1_024], id: \.self) { value in
                        Text(value >= 1_024 ? "\(value / 1_024) GB" : "\(value) MB").tag(value)
                    }
                }
            } header: {
                Text("Proxy")
            } footer: {
                Text("Larger uploads are refused with 413. Your tunnels are public, so this keeps anyone from filling this Mac's memory.")
            }

            Section {
                Picker("Requests Kept per Tunnel", selection: $requestHistoryLimit) {
                    ForEach([100, 500, 1_000, 5_000, 10_000], id: \.self) { value in
                        Text(value.formatted()).tag(value)
                    }
                }
                Picker("Body Size Kept", selection: $maxCapturedBodyKB) {
                    ForEach([64, 256, 1_024, 5_120, 10_240], id: \.self) { value in
                        Text(value >= 1_024 ? "\(value / 1_024) MB" : "\(value) KB").tag(value)
                    }
                }
            } header: {
                Text("History")
            } footer: {
                Text("Older requests are deleted as new ones arrive; saved requests are always kept. Longer bodies are cut off in the inspector but reach your app in full.")
            }

            Section {
                Toggle("Hide Credentials in History", isOn: $redactsSensitiveHeaders)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Authorization, Cookie, Set-Cookie and X-Api-Key values are masked before being stored. Replaying those requests will not include them.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct CloudflaredSettingsView: View {
    @State private var cloudflared = CloudflaredManager()

    var body: some View {
        Form {
            Section {
                LabeledContent("Installation") { installationStatus }

                if case let .installed(_, version) = cloudflared.status {
                    LabeledContent("Version") {
                        HStack(spacing: 10) {
                            Text(version)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            UpdateControl(
                                availableUpdate: cloudflared.availableUpdate,
                                isUpdating: cloudflared.isUpdating,
                                didCheck: cloudflared.didCheckForUpdates
                            ) {
                                Task { await cloudflared.update() }
                            }
                        }
                    }
                }

                if let error = cloudflared.updateError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Environment")
            } footer: {
                Text("Quick Tunnels give each tunnel a temporary trycloudflare.com address.")
            }
        }
        .formStyle(.grouped)
        .task {
            await cloudflared.checkInstallation()
            await cloudflared.checkForUpdates()
        }
    }

    @ViewBuilder
    private var installationStatus: some View {
        switch cloudflared.status {
        case .checking:
            ProgressView().controlSize(.small)
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .missing:
            Label("Not Installed", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .installing:
            Label("Installing", systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case .failure:
            Label("Check Failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

private struct RelaySettingsView: View {
    @State private var relay = RelayManager()
    @AppStorage(RelayManager.domainKey) private var domain = ""
    @AppStorage(RelayManager.accountTokenKey) private var accountToken = ""
    @AppStorage(RelayManager.adminTokenKey) private var adminToken = ""
    @State private var isConnected = false
    @State private var isConnecting = false
    @State private var connectionError: String?

    private var canConnect: Bool {
        RelayManager.apiURL(forDomain: domain) != nil
            && !accountToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && relay.status != .missing
            && !isConnecting
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Installation") {
                    HStack(spacing: 10) {
                        installationStatus
                        installationButton
                    }
                }

                if case let .installed(_, version) = relay.status {
                    LabeledContent("Version") {
                        HStack(spacing: 10) {
                            Text(version)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            UpdateControl(
                                availableUpdate: relay.availableUpdate,
                                isUpdating: relay.isUpdating,
                                didCheck: relay.didCheckForUpdates
                            ) {
                                Task { await relay.update() }
                            }
                        }
                    }
                }

                if let error = relay.updateError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                if case let .failure(message) = relay.status {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Environment")
            } footer: {
                Text("Permanent public addresses for your apps. Updates stay on version \(RelayManager.supportedMajorVersion).x to match the server and are verified before installing; running tunnels use the new version after a restart.")
            }

            Section("Server") {
                TextField("Domain", text: $domain, prompt: Text("tunnels.example.com"))
                    .onSubmit { domain = RelayManager.normalizedDomain(domain) }
                SecureField("Access Token", text: $accountToken, prompt: Text("Provided by your admin"))

                if let apiURL = RelayManager.apiURL(forDomain: domain) {
                    LabeledContent("API") {
                        Text(apiURL.absoluteString)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                }

                LabeledContent("This Mac") {
                    HStack(spacing: 10) {
                        connectionStatus
                        connectionButton
                    }
                }

                if let connectionError {
                    Label(connectionError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section {
                SecureField("Admin Token", text: $adminToken, prompt: Text("Optional"))
            } header: {
                Text("Developer")
            } footer: {
                Text("Lets this Mac add and remove relay users.")
            }
        }
        .formStyle(.grouped)
        .task {
            await relay.checkInstallation()
            await relay.checkForUpdates()
        }
        .onAppear { refreshConnection() }
        .onChange(of: domain) { refreshConnection() }
        .onDisappear { domain = RelayManager.normalizedDomain(domain) }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        if isConnecting {
            ProgressView().controlSize(.small)
        } else if isConnected {
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Label("Not Connected", systemImage: "circle")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var connectionButton: some View {
        if isConnected {
            Button("Disconnect", role: .destructive) {
                Task { await run { try await relay.disconnect() } }
            }
            .disabled(isConnecting)
        } else {
            Button("Connect") {
                domain = RelayManager.normalizedDomain(domain)
                let token = accountToken.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await run { try await relay.connect(domain: domain, accountToken: token) } }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canConnect)
        }
    }

    private func refreshConnection() {
        isConnected = RelayManager.isConnected(domain: domain)
    }

    private func run(_ action: () async throws -> Void) async {
        isConnecting = true
        connectionError = nil
        defer {
            isConnecting = false
            refreshConnection()
        }
        do {
            try await action()
        } catch {
            connectionError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var installationButton: some View {
        switch relay.status {
        case .missing:
            Button("Install") { Task { await relay.install() } }
                .buttonStyle(.borderedProminent)
        case .failure:
            Button("Retry") { Task { await relay.install() } }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var installationStatus: some View {
        switch relay.status {
        case .checking:
            ProgressView().controlSize(.small)
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .missing:
            Label("Not Installed", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing…")
            }
            .foregroundStyle(.secondary)
        case .failure:
            Label("Install Failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

/// "Update to X" when a newer version exists, "Up to date" once a check found none.
private struct UpdateControl: View {
    let availableUpdate: SemanticVersion?
    let isUpdating: Bool
    let didCheck: Bool
    let onUpdate: () -> Void

    var body: some View {
        if isUpdating {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Updating…")
            }
            .foregroundStyle(.secondary)
        } else if let availableUpdate {
            Button("Update to \(availableUpdate)", action: onUpdate)
                .buttonStyle(.borderedProminent)
        } else if didCheck {
            Label("Up to date", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}
