import SwiftUI

struct EditTunnelView: View {
    @Environment(\.dismiss) private var dismiss

    let tunnel: Tunnel
    /// Called after the changes are applied to `tunnel`.
    let onSave: () -> Void

    @State private var name: String
    @State private var port: String
    @State private var startsAutomatically: Bool
    @State private var routes: [RouteDraft]

    init(tunnel: Tunnel, onSave: @escaping () -> Void) {
        self.tunnel = tunnel
        self.onSave = onSave
        _name = State(initialValue: tunnel.name)
        _port = State(initialValue: String(tunnel.localPort))
        _startsAutomatically = State(initialValue: tunnel.startsAutomatically)
        _routes = State(initialValue: tunnel.routes.map(RouteDraft.init))
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var portNumber: Int? {
        guard let value = Int(port), (1...65_535).contains(value) else { return nil }
        return value
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && portNumber != nil && routes.allSatisfy(\.isValid)
    }

    private var address: String {
        switch tunnel.provider {
        case .quick: "Quick Tunnel (trycloudflare.com)"
        case .relay: tunnel.relayURL?.host() ?? tunnel.domain
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Edit Tunnel")
                    .font(.title2.weight(.semibold))
                Text(tunnel.name)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("API"))
                    TextField("Local Port", text: $port, prompt: Text("8000"))
                    LabeledContent("Address") {
                        Text(address)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } footer: {
                    Text("Requests that match no route go to http://localhost:\(portNumber.map(String.init) ?? port).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                RoutesSection(
                    routes: $routes,
                    note: "The longest matching path wins. Changes apply immediately, even while the tunnel is running."
                )
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Toggle("Auto-start", isOn: $startsAutomatically)
                    .help("Start this tunnel when Tunnelz opens")
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 540, height: 480)
    }

    private func save() {
        guard canSave, let portNumber else { return }

        tunnel.name = trimmedName
        tunnel.localPort = portNumber
        tunnel.startsAutomatically = startsAutomatically
        tunnel.routes = routes.compactMap(\.route)

        onSave()
        dismiss()
    }
}

/// Path routes shared by the add and edit forms.
struct RoutesSection: View {
    @Binding var routes: [RouteDraft]
    let note: String

    var body: some View {
        Section {
            ForEach($routes) { $route in
                RouteRow(route: $route) {
                    routes.removeAll { $0.id == route.id }
                }
            }
            Button("Add Route", systemImage: "plus") {
                routes.append(RouteDraft())
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Routes")
        } footer: {
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Editable form of a `TunnelRoute`, with the port kept as text while typing.
struct RouteDraft: Identifiable {
    var id = UUID()
    var path = ""
    var port = ""
    var stripsPrefix = false
    var capturesRequests = true

    init() {}

    init(_ route: TunnelRoute) {
        id = route.id
        path = route.pathPrefix
        port = String(route.port)
        stripsPrefix = route.stripsPrefix
        capturesRequests = route.capturesRequests
    }

    var portNumber: Int? {
        guard let value = Int(port), (1...65_535).contains(value) else { return nil }
        return value
    }

    var isValid: Bool {
        !path.trimmingCharacters(in: .whitespaces).isEmpty && portNumber != nil
    }

    var route: TunnelRoute? {
        guard isValid, let portNumber else { return nil }
        return TunnelRoute(
            id: id,
            pathPrefix: TunnelRoute.normalizedPrefix(path),
            port: portNumber,
            stripsPrefix: stripsPrefix,
            capturesRequests: capturesRequests
        )
    }
}

private struct RouteRow: View {
    @Binding var route: RouteDraft
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Path", text: $route.path, prompt: Text("/api"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            TextField("Port", text: $route.port, prompt: Text("8000"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
            Toggle("Strip", isOn: $route.stripsPrefix)
                .toggleStyle(.checkbox)
                .help("Remove the path prefix before forwarding (/api/users → /users)")
            Toggle(isOn: $route.capturesRequests) {
                Image(systemName: route.capturesRequests ? "record.circle" : "record.circle.fill")
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .foregroundStyle(route.capturesRequests ? Color.green : Color.secondary)
            .help(route.capturesRequests ? "Capturing requests on this route" : "Not capturing requests on this route")
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove route")
        }
    }
}
