import SwiftUI

struct SidebarView: View {
    @State private var tunnelPendingRemoval: Tunnel?

    let tunnels: [Tunnel]
    @Binding var selection: Tunnel.ID?
    let processManager: TunnelProcessManager
    let onAddTunnel: () -> Void
    let onEditTunnel: (Tunnel) -> Void
    let onRemoveTunnel: (Tunnel) -> Void

    var body: some View {
        List(selection: $selection) {
            Section("Tunnels") {
                ForEach(tunnels) { tunnel in
                    HStack(spacing: 9) {
                        Circle()
                            .fill(statusColor(for: tunnel))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tunnel.name)
                            Text(tunnel.localURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        let requestCount = processManager.requests(for: tunnel.id).count
                        if requestCount > 0 {
                            Text(requestCount, format: .number)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tag(tunnel.id)
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button(actionTitle(for: tunnel)) {
                            processManager.toggle(tunnel)
                        }

                        Button("Copy Public Link", systemImage: "doc.on.doc") {
                            if let url = processManager.state(for: tunnel.id).publicURL {
                                Pasteboard.copy(url.absoluteString)
                            }
                        }
                        .disabled(processManager.state(for: tunnel.id).publicURL == nil)

                        Button("Edit Tunnel…", systemImage: "pencil") {
                            onEditTunnel(tunnel)
                        }

                        Divider()

                        Button("Remove Tunnel", systemImage: "trash", role: .destructive) {
                            tunnelPendingRemoval = tunnel
                        }

                        if processManager.state(for: tunnel.id).phase == .error,
                           let message = processManager.state(for: tunnel.id).errorMessage {
                            Divider()
                            Text(message)
                        }
                    }
                }
            }
        }
        .contextMenu(forSelectionType: Tunnel.ID.self, menu: { _ in }) { ids in
            // Double-click opens the tunnel's public address.
            guard let id = ids.first, let url = processManager.state(for: id).publicURL else { return }
            NSWorkspace.shared.open(url)
        }
        .listStyle(.sidebar)
        .navigationTitle("Tunnelz")
        .alert(
            "Remove Tunnel?",
            isPresented: Binding(
                get: { tunnelPendingRemoval != nil },
                set: { if !$0 { tunnelPendingRemoval = nil } }
            ),
            presenting: tunnelPendingRemoval
        ) { tunnel in
            Button("Remove", role: .destructive) {
                onRemoveTunnel(tunnel)
                tunnelPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                tunnelPendingRemoval = nil
            }
        } message: { tunnel in
            Text("“\(tunnel.name)” will be stopped and removed from this Mac.")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Button("Add Tunnel", systemImage: "plus", action: onAddTunnel)
                        .labelStyle(.titleAndIcon)

                    Spacer()

                    SettingsLink {
                        Label("Settings", systemImage: "gearshape")
                    }
                        .labelStyle(.iconOnly)
                        .help("Settings")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }

    private func statusColor(for tunnel: Tunnel) -> Color {
        switch processManager.state(for: tunnel.id).phase {
        case .running: .green
        case .starting, .stopping: .orange
        case .error: .red
        case .stopped: .secondary
        }
    }

    private func actionTitle(for tunnel: Tunnel) -> String {
        switch processManager.state(for: tunnel.id).phase {
        case .starting, .running: "Stop Tunnel"
        case .stopped, .error: "Start Tunnel"
        case .stopping: "Stopping…"
        }
    }
}
