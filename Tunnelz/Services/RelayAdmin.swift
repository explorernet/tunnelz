import Foundation

struct RelayMember: Identifiable, Hashable {
    var id: String { email }
    let email: String
    let isAdmin: Bool
}

/// User management on the relay server. Every account created here is added to a
/// single organization so it can be listed later (the server has no "list accounts").
@MainActor
struct RelayAdmin {
    static let organizationName = "Tunnelz"
    static let organizationTokenKey = "relay.organizationToken"
    static let organizationDomainKey = "relay.organizationDomain"

    let relay: RelayManager
    let domain: String
    let adminToken: String

    func listMembers() async throws -> [RelayMember] {
        try await withOrganization { organization in
            let output = try await admin(["list", "org-members", organization])
            return Self.tableRows(output).compactMap { cells in
                guard let email = cells.first, !email.isEmpty else { return nil }
                return RelayMember(email: email, isAdmin: cells.dropFirst().first == "true")
            }
        }
    }

    /// Creates the account and adds it to the organization. Returns the account's access token.
    func createUser(email: String, password: String) async throws -> String {
        let organization = try await organizationToken()
        let output = try await admin(["create", "account", email, password])
        // The command prints only the account's enable token.
        guard let token = output
            .split(whereSeparator: \.isNewline)
            .last
            .map({ String($0).trimmingCharacters(in: .whitespaces) }),
            !token.isEmpty
        else {
            throw RelayAdminError.unexpectedOutput("The server did not return an access token.")
        }

        _ = try await admin(["create", "org-member", organization, email])
        return token
    }

    /// Order matters: once the account is deleted, its membership can no longer be removed
    /// and it keeps showing up in the member list.
    func removeUser(email: String) async throws {
        try await withOrganization { organization in
            _ = try await admin(["delete", "org-member", organization, email])
        }
        _ = try await admin(["delete", "account", email])
    }

    // MARK: - Organization

    /// Runs `body` with the cached organization token, re-resolving once if the cache is stale.
    private func withOrganization<T>(_ body: (String) async throws -> T) async throws -> T {
        let organization = try await organizationToken()
        do {
            return try await body(organization)
        } catch {
            guard Self.isNotFound(error) else { throw error }
            Self.clearCachedOrganization()
            return try await body(try await organizationToken())
        }
    }

    private func organizationToken() async throws -> String {
        let defaults = UserDefaults.standard
        let normalizedDomain = RelayManager.normalizedDomain(domain)
        if let cached = defaults.string(forKey: Self.organizationTokenKey), !cached.isEmpty,
           defaults.string(forKey: Self.organizationDomainKey) == normalizedDomain {
            return cached
        }

        let token: String
        if let existing = try await findOrganization() {
            token = existing
        } else {
            token = try await createOrganization()
        }
        defaults.set(token, forKey: Self.organizationTokenKey)
        defaults.set(normalizedDomain, forKey: Self.organizationDomainKey)
        return token
    }

    private func findOrganization() async throws -> String? {
        let output = try await admin(["list", "organizations"])
        return Self.tableRows(output)
            .first { $0.count >= 2 && $0[1] == Self.organizationName }?
            .first
    }

    private func createOrganization() async throws -> String {
        // The token is only reported inside a log line: "…organization token 'sEasuT1qyJTX'".
        let output = try await admin(["create", "organization", "-d", Self.organizationName])
        guard let range = output.range(of: #"token '([^']+)'"#, options: .regularExpression) else {
            throw RelayAdminError.unexpectedOutput("Could not read the organization token.")
        }
        return String(output[range].dropFirst("token '".count).dropLast())
    }

    static func clearCachedOrganization() {
        UserDefaults.standard.removeObject(forKey: organizationTokenKey)
        UserDefaults.standard.removeObject(forKey: organizationDomainKey)
    }

    // MARK: - Helpers

    private func admin(_ arguments: [String]) async throws -> String {
        try await relay.runAdmin(arguments, domain: domain, adminToken: adminToken)
    }

    private static func isNotFound(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("notfound") || message.contains("[404]")
    }

    /// Parses the CLI's box-drawn tables, skipping the header row.
    ///
    ///     │ ACCOUNT EMAIL      │ ADMIN? │
    ///     ├────────────────────┼────────┤
    ///     │ someone@company.com│ false  │
    static func tableRows(_ output: String) -> [[String]] {
        let rows = output
            .split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("│") }
            .map { line in
                line.split(separator: "│").map { $0.trimmingCharacters(in: .whitespaces) }
            }
        return Array(rows.dropFirst())
    }
}

enum RelayAdminError: LocalizedError {
    case unexpectedOutput(String)

    var errorDescription: String? {
        switch self {
        case let .unexpectedOutput(message): message
        }
    }
}
