import AppKit
import SwiftData
import SwiftUI

struct MenuBarView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \Tunnel.createdAt) private var tunnels: [Tunnel]

    let processManager: TunnelProcessManager

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Text("Tunnels")
                    .font(.headline)
                Spacer()

                Button("Open App", systemImage: "macwindow") {
                    showMainWindow()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .frame(width: 28, height: 24)
                .menuHoverFeedback()
                .help("Open App")

                Button("Add Tunnel", systemImage: "plus") {
                    showAddTunnelWindow()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .frame(width: 28, height: 24)
                .menuHoverFeedback()
                .help("Add Tunnel")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if tunnels.isEmpty {
                ContentUnavailableView(
                    "No Tunnels",
                    systemImage: "circle.dashed",
                    description: Text("Add a tunnel to expose a local port.")
                )
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(tunnels) { tunnel in
                            tunnelRow(tunnel)
                                .contextMenu {
                                    Button("Open Public URL", systemImage: "safari") {
                                        openPublicURL(for: tunnel)
                                    }
                                    .disabled(publicURL(for: tunnel) == nil)

                                    Button("Copy Endpoint", systemImage: "doc.on.doc") {
                                        copyEndpoint(for: tunnel)
                                    }
                                    .disabled(publicURL(for: tunnel) == nil)
                                }
                        }
                    }
                    .padding(6)
                }
                .frame(minHeight: 120, maxHeight: 320)
            }

            Divider()

            HStack(spacing: 8) {
                Button("Add Tunnel", systemImage: "plus") {
                    showAddTunnelWindow()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .menuHoverFeedback()

                Spacer()

                Button("Quit", systemImage: "power", role: .destructive) {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .menuHoverFeedback()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(width: 340)
        .task {
            processManager.configurePersistence(modelContext)
            processManager.restoreTunnelsOnLaunch(tunnels)
        }
    }

    private func tunnelRow(_ tunnel: Tunnel) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shortTitle(tunnel.name))
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(verbatim: ":\(String(tunnel.localPort))")
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)

                    Text(verbatim: publicURL(for: tunnel)?.absoluteString ?? "Not connected")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            Button(actionTitle(for: tunnel), systemImage: actionIcon(for: tunnel)) {
                processManager.toggle(tunnel)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .frame(width: 28, height: 24)
            .menuHoverFeedback()
            .disabled(processManager.state(for: tunnel.id).phase == .stopping)
            .help(actionTitle(for: tunnel))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { openPublicURL(for: tunnel) }
        .menuHoverFeedback(cornerRadius: 7)
    }

    private func publicURL(for tunnel: Tunnel) -> URL? {
        processManager.state(for: tunnel.id).publicURL
    }

    private func openPublicURL(for tunnel: Tunnel) {
        guard let url = publicURL(for: tunnel) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyEndpoint(for tunnel: Tunnel) {
        guard let url = publicURL(for: tunnel) else { return }
        Pasteboard.copy(url.absoluteString)
    }

    private func showMainWindow() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first(where: {
            !$0.isSheet && !($0 is NSPanel) && $0.styleMask.contains(.titled) && $0.canBecomeMain
        }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }

    private func showAddTunnelWindow() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "add-tunnel")
    }

    private func shortTitle(_ title: String) -> String {
        title.count <= 30 ? title : String(title.prefix(27)) + "…"
    }

    private func actionTitle(for tunnel: Tunnel) -> String {
        switch processManager.state(for: tunnel.id).phase {
        case .starting, .running: "Stop Tunnel"
        case .stopping: "Stopping Tunnel"
        case .stopped, .error: "Start Tunnel"
        }
    }

    private func actionIcon(for tunnel: Tunnel) -> String {
        switch processManager.state(for: tunnel.id).phase {
        case .starting, .running: "stop.fill"
        case .stopping: "hourglass"
        case .stopped, .error: "play.fill"
        }
    }
}

private struct MenuHoverFeedback: ViewModifier {
    @State private var isHovering = false

    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                isHovering ? Color.primary.opacity(0.09) : .clear,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.08), value: isHovering)
    }
}

private extension View {
    func menuHoverFeedback(cornerRadius: CGFloat = 5) -> some View {
        modifier(MenuHoverFeedback(cornerRadius: cornerRadius))
    }
}
