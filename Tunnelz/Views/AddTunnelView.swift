import SwiftUI

struct AddTunnelView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    let onCreate: (Tunnel) -> Void

    @State private var name = ""
    @State private var port = ""
    @State private var startsAutomatically = true
    @State private var provider = TunnelProvider.quick
    @State private var subdomain = ""
    @State private var routes: [RouteDraft] = []
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var relay = RelayManager()
    @AppStorage(RelayManager.domainKey) private var relayDomain = ""

    private enum Field { case name, port, subdomain }

    @State private var isRelayAvailable = false

    private func refreshRelayAvailability() {
        isRelayAvailable = RelayManager.isConnected(domain: relayDomain)
    }

    /// DNS label: lowercase letters, digits and inner hyphens.
    private var normalizedSubdomain: String {
        subdomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var isSubdomainValid: Bool {
        normalizedSubdomain.range(of: #"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$"#, options: .regularExpression) != nil
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var portNumber: Int? {
        guard let value = Int(port), (1...65_535).contains(value) else { return nil }
        return value
    }

    private var canCreate: Bool {
        guard !trimmedName.isEmpty, portNumber != nil, !isCreating, routes.allSatisfy(\.isValid) else { return false }
        return provider == .quick || (isRelayAvailable && isSubdomainValid)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("API"))
                        .focused($focusedField, equals: .name)
                    TextField("Local Port", text: $port, prompt: Text("8000"))
                        .focused($focusedField, equals: .port)
                }

                Section {
                    Picker("Address", selection: $provider) {
                        Text("Quick").tag(TunnelProvider.quick)
                        Text("Relay").tag(TunnelProvider.relay)
                    }
                    .pickerStyle(.segmented)

                    if provider == .relay && !isRelayAvailable {
                        LabeledContent("This Mac isn't connected to the relay") {
                            SettingsLink {
                                Text("Open Settings…")
                            }
                        }
                    } else if provider == .relay {
                        LabeledContent("Subdomain") {
                            HStack(spacing: 4) {
                                TextField("Subdomain", text: $subdomain, prompt: Text("api"))
                                    .labelsHidden()
                                    .multilineTextAlignment(.trailing)
                                    .focused($focusedField, equals: .subdomain)
                                Text(".\(RelayManager.normalizedDomain(relayDomain))")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Group {
                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        } else {
                            Text(addressHelp)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                RoutesSection(
                    routes: $routes,
                    note: "Send paths to other local ports, e.g. /api → 8000. The longest matching path wins; everything else goes to the local port above."
                )
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(width: 540, height: 520)
        .onAppear { refreshRelayAvailability() }
        // Picks up a connection made in Settings while this window stayed open.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshRelayAvailability()
        }
        .onChange(of: provider) { errorMessage = nil }
        .onChange(of: subdomain) { errorMessage = nil }
        .onAppear { focusedField = .name }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Add Tunnel")
                .font(.title2.weight(.semibold))
            Text("Expose an application running on your Mac.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Toggle("Auto-start", isOn: $startsAutomatically)
                .help("Start the tunnel right after creating it")
            Spacer()

            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            if isCreating {
                ProgressView().controlSize(.small)
            }
            Button("Create Tunnel") { Task { await createTunnel() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
        }
        .padding(16)
    }

    private var addressHelp: String {
        switch provider {
        case .quick:
            "A temporary trycloudflare.com address that changes on every start."
        case .relay where !isRelayAvailable:
            "Connect this Mac in Settings → Relay, then come back to choose a subdomain."
        case .relay where !normalizedSubdomain.isEmpty && !isSubdomainValid:
            "Use lowercase letters, numbers and hyphens."
        case .relay:
            "A permanent address reserved for you. Requests go to http://localhost:\(port.isEmpty ? "8000" : port)."
        }
    }

    private func createTunnel() async {
        guard canCreate, let portNumber else { return }

        let tunnel: Tunnel
        switch provider {
        case .quick:
            tunnel = Tunnel(
                name: trimmedName,
                localPort: portNumber,
                startsAutomatically: startsAutomatically
            )
        case .relay:
            isCreating = true
            errorMessage = nil
            defer { isCreating = false }
            do {
                // Reserving fails right here if someone else already owns the address.
                try await relay.reserveName(normalizedSubdomain)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            tunnel = Tunnel(
                name: trimmedName,
                localPort: portNumber,
                domain: RelayManager.normalizedDomain(relayDomain),
                provider: .relay,
                relayName: normalizedSubdomain,
                startsAutomatically: startsAutomatically
            )
        }

        tunnel.routes = routes.compactMap(\.route)
        onCreate(tunnel)
        dismiss()
    }
}

#Preview {
    AddTunnelView { _ in }
}
