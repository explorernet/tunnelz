import SwiftUI

/// Accounts in the relay organization, managed with the admin token.
struct RelayUsersView: View {
    @State private var relay = RelayManager()
    @AppStorage(RelayManager.domainKey) private var domain = ""
    @AppStorage(RelayManager.adminTokenKey) private var adminToken = ""

    @State private var members: [RelayMember] = []
    @State private var isAdding = false
    @State private var pendingRemoval: RelayMember?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var admin: RelayAdmin {
        RelayAdmin(relay: relay, domain: domain, adminToken: adminToken)
    }

    var body: some View {
        Form {
            Section {
                if members.isEmpty {
                    Text(isLoading ? "Loading users…" : "No users yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(members) { member in
                        UserRow(member: member) {
                            pendingRemoval = member
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Users")
                    Spacer()
                    if isLoading {
                        ProgressView().controlSize(.small)
                    }
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await refresh() }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(isLoading)
                    .help("Refresh")
                    Button("Add User", systemImage: "plus") {
                        isAdding = true
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(isLoading)
                    .help("Add User")
                }
            } footer: {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } else {
                    Text("People who can create relay tunnels. New users receive a setup link to connect their Mac.")
                }
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .sheet(isPresented: $isAdding) {
            AddRelayUserSheet { email, password in
                let token = try await admin.createUser(email: email, password: password)
                await refresh()
                return token
            }
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.email ?? "")?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { member in
            Button("Remove User", role: .destructive) {
                Task { await remove(member) }
            }
        } message: { _ in
            Text("The account and all of its tunnels and reserved addresses are deleted from the server.")
        }
    }

    private func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            members = try await admin.listMembers()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ member: RelayMember) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            try await admin.removeUser(email: member.email)
            members.removeAll { $0.email == member.email }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct UserRow: View {
    let member: RelayMember
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(member.email)
            if member.isAdmin {
                Text("Admin")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.purple.opacity(0.15), in: Capsule())
            }
            Spacer()
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove user")
        }
        .padding(.vertical, 4)
    }
}

private struct AddRelayUserSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onCreate: (String, String) async throws -> String

    @AppStorage(RelayManager.domainKey) private var domain = ""

    @State private var email = ""
    @State private var password = AddRelayUserSheet.generatePassword()
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var created: (email: String, token: String)?

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var canCreate: Bool {
        trimmedEmail.contains("@") && password.count >= 8 && !isCreating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(created == nil ? "Add User" : "User Created")
                .font(.title2.weight(.semibold))

            if let created {
                Text("Send this link to \(created.email). Opening it on their Mac sets up the relay. It is shown only once.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let link = RelayManager.connectLink(domain: domain, token: created.token) {
                    copyRow("Setup Link", value: link.absoluteString)
                }
                copyRow("Access Token", value: created.token)

                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }} else {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Email").font(.headline)
                    TextField("name@company.com", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("Password").font(.headline)
                    HStack {
                        TextField("Password", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .font(.system(.body, design: .monospaced))
                        Button {
                            password = Self.generatePassword()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Generate a new password")
                    }
                    Text("Only needed to sign in to the web console. The app uses the access token.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button {
                        Task { await create() }
                    } label: {
                        if isCreating {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Create User")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func copyRow(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            HStack {
                Text(value)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Copy") { Pasteboard.copy(value) }
            }
            .padding(10)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func create() async {
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        do {
            created = (trimmedEmail, try await onCreate(trimmedEmail, password))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func generatePassword() -> String {
        let letters = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        // Letters, then a random digit and symbol so server password rules are always met.
        let body = String((0..<14).map { _ in letters.randomElement()! })
        return body + String("23456789".randomElement()!) + String("!@#$%&*".randomElement()!)
    }
}
