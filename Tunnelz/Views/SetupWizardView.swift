import SwiftUI

/// First-launch setup: Quick Tunnels (cloudflared) and the relay. Both steps are optional.
struct SetupWizardView: View {
    private enum Step: Int, CaseIterable { case cloudflare, relay }

    let cloudflared: CloudflaredManager
    let onFinish: () -> Void

    @State private var step: Step = .cloudflare

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 32)

            Group {
                switch step {
                case .cloudflare:
                    CloudflareStep(manager: cloudflared) { step = .relay }
                case .relay:
                    RelayStep(onBack: { step = .cloudflare }, onFinish: onFinish)
                }
            }
            .frame(maxWidth: 440)
            .padding(32)
            .transition(.push(from: .trailing))

            Spacer()

            HStack(spacing: 8) {
                ForEach(Step.allCases, id: \.self) { item in
                    Capsule()
                        .fill(item == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: item == step ? 18 : 7, height: 7)
                }
            }
            .padding(.bottom, 24)
        }
        .frame(minWidth: 620, minHeight: 520)
        .animation(.smooth, value: step)
    }
}

// MARK: - Shared layout

private struct StepLayout<Content: View, Actions: View>: View {
    let systemImage: String
    let color: Color
    let title: String
    let message: String
    var isWorking = false
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: systemImage)
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(color)
                .symbolEffect(.pulse, isActive: isWorking)
                .frame(height: 56)

            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content

            HStack {
                actions
            }
        }
    }
}

private struct ErrorBox: View {
    let message: String

    var body: some View {
        ScrollView {
            Text(message)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: 100)
        .background(.background, in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).stroke(.separator) }
    }
}

// MARK: - Step 1: Quick Tunnels

private struct CloudflareStep: View {
    let manager: CloudflaredManager
    let onContinue: () -> Void

    var body: some View {
        StepLayout(
            systemImage: iconName,
            color: iconColor,
            title: "Quick Tunnels",
            message: message,
            isWorking: manager.status == .checking || manager.status == .installing
        ) {
            if case let .failure(error) = manager.status {
                ErrorBox(message: error)
            }
        } actions: {
            switch manager.status {
            case .checking, .installing:
                ProgressView().controlSize(.small)
            case .installed:
                Button("Continue", action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .missing, .failure:
                Button("Skip", action: onContinue)
                Button(manager.status == .missing ? "Install cloudflared" : "Try Again") {
                    Task { await manager.install() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var iconName: String {
        switch manager.status {
        case .installed: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle"
        case .installing: "arrow.down.circle"
        default: "cloud"
        }
    }

    private var iconColor: Color {
        switch manager.status {
        case .installed: .green
        case .failure: .red
        default: .orange
        }
    }

    private var message: String {
        switch manager.status {
        case .checking:
            "Looking for cloudflared on this Mac…"
        case .missing:
            "Temporary trycloudflare.com addresses, no account needed. Optional: installs cloudflared with Homebrew. You can do this later in Settings."
        case .installing:
            "Homebrew is installing cloudflared. This can take a moment."
        case let .installed(_, version):
            "cloudflared is ready. \(version)"
        case .failure:
            "cloudflared couldn't be installed. Try again, or skip and set it up later in Settings."
        }
    }
}

// MARK: - Step 2: Relay

private struct RelayStep: View {
    let onBack: () -> Void
    let onFinish: () -> Void

    @State private var relay = RelayManager()
    @AppStorage(RelayManager.domainKey) private var domain = ""
    @AppStorage(RelayManager.accountTokenKey) private var accountToken = ""
    @State private var isConnecting = false
    @State private var isConnected = false
    @State private var errorMessage: String?

    private var canConnect: Bool {
        !isConnecting
            && RelayManager.apiURL(forDomain: domain) != nil
            && !accountToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        StepLayout(
            systemImage: isConnected ? "checkmark.circle.fill" : "point.3.connected.trianglepath.dotted",
            color: isConnected ? .green : .purple,
            title: "Relay",
            message: isConnected
                ? "This Mac is connected to \(domain). Relay tunnels get permanent addresses."
                : "Permanent addresses like app.\(domain.isEmpty ? "your-domain.com" : domain). Enter the details from your admin, or paste the setup link in the token field.",
            isWorking: isConnecting
        ) {
            if !isConnected {
                Form {
                    TextField("Domain", text: $domain, prompt: Text("tunnels.example.com"))
                    SecureField("Access Token", text: $accountToken, prompt: Text("Token or tunnelz:// link"))
                        .onChange(of: accountToken) { applySetupLink() }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .frame(height: 130)
                .disabled(isConnecting)
            }
            if let errorMessage {
                ErrorBox(message: errorMessage)
            }
        } actions: {
            if isConnected {
                Button("Finish", action: onFinish)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Back", action: onBack)
                    .disabled(isConnecting)
                Spacer().frame(width: 12)
                Button("Skip", action: onFinish)
                    .disabled(isConnecting)
                Button {
                    Task { await connect() }
                } label: {
                    if isConnecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Connect")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect)
            }
        }
        .onAppear {
            isConnected = RelayManager.isConnected(domain: domain)
        }
    }

    /// A pasted tunnelz:// link fills both fields.
    private func applySetupLink() {
        guard let url = URL(string: accountToken.trimmingCharacters(in: .whitespacesAndNewlines)),
              let link = RelayManager.parseConnectLink(url) else { return }
        domain = link.domain
        accountToken = link.token
    }

    private func connect() async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        domain = RelayManager.normalizedDomain(domain)
        let token = accountToken.trimmingCharacters(in: .whitespacesAndNewlines)

        await relay.checkInstallation()
        if case .installed = relay.status {} else {
            await relay.install()
            if case let .failure(message) = relay.status {
                errorMessage = "Could not install the relay client: \(message)"
                return
            }
        }

        do {
            try await relay.connect(domain: domain, accountToken: token)
            isConnected = RelayManager.isConnected(domain: domain)
            if !isConnected { errorMessage = "The relay did not confirm the connection. Check the domain and token." }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    SetupWizardView(cloudflared: CloudflaredManager()) { }
}
