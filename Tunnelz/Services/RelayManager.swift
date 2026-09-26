import CryptoKit
import Foundation
import Observation

/// Manages the relay client binary (zrok2) used for self-hosted tunnels.
@MainActor
@Observable
final class RelayManager {
    enum Status: Equatable {
        case checking
        case missing
        case installing
        case installed(path: String, version: String)
        case failure(String)
    }

    /// The client must match the server's major version, so updates stay within it.
    nonisolated static let supportedMajorVersion = 2
    static let domainKey = "relay.domain"
    static let accountTokenKey = "relay.accountToken"
    static let adminTokenKey = "relay.adminToken"

    /// Strips scheme, path and whitespace: "https://Tunnels.Example.com/" → "tunnels.example.com".
    nonisolated static func normalizedDomain(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = value.range(of: "://") { value = String(value[range.upperBound...]) }
        if let slash = value.firstIndex(of: "/") { value = String(value[..<slash]) }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    /// One-click setup link sent to new users: tunnelz://relay?domain=…&token=…
    nonisolated static func connectLink(domain: String, token: String) -> URL? {
        var components = URLComponents()
        components.scheme = "tunnelz"
        components.host = "relay"
        components.queryItems = [
            URLQueryItem(name: "domain", value: normalizedDomain(domain)),
            URLQueryItem(name: "token", value: token)
        ]
        return components.url
    }

    /// Parses a link built by `connectLink`.
    nonisolated static func parseConnectLink(_ url: URL) -> (domain: String, token: String)? {
        guard url.scheme == "tunnelz", url.host == "relay",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let domain = items.first(where: { $0.name == "domain" })?.value.map(normalizedDomain),
              let token = items.first(where: { $0.name == "token" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              apiURL(forDomain: domain) != nil, !token.isEmpty
        else { return nil }
        return (domain, token)
    }

    /// The relay API lives at zrok2.<domain>; public tunnels at <name>.<domain>.
    nonisolated static func apiURL(forDomain domain: String) -> URL? {
        let host = normalizedDomain(domain)
        guard host.contains("."), !host.contains(" ") else { return nil }
        return URL(string: "https://zrok2.\(host)")
    }

    private(set) var status: Status = .checking
    private(set) var availableUpdate: SemanticVersion?
    private(set) var isUpdating = false
    private(set) var didCheckForUpdates = false
    private(set) var updateError: String?

    /// Only the copy in Application Support is updated here; others belong to Homebrew.
    var isManagedInstall: Bool {
        guard case let .installed(path, _) = status else { return false }
        return path == Self.managedBinaryURL.path(percentEncoded: false)
    }

    func checkForUpdates() async {
        guard isManagedInstall, case let .installed(_, versionText) = status,
              let installed = SemanticVersion(versionText) else { return }
        do {
            let latest = try await Self.latestRelease()
            availableUpdate = latest.version > installed ? latest.version : nil
            didCheckForUpdates = true
        } catch {
            // A failed check (offline, rate limit) just leaves the button hidden.
            didCheckForUpdates = false
        }
    }

    func update() async {
        isUpdating = true
        updateError = nil
        defer { isUpdating = false }
        do {
            try await Self.downloadAndInstall()
            if case let .success(installation) = await Task.detached(operation: { Self.detectRelay() }).value {
                status = .installed(path: installation.path, version: installation.version)
            }
            availableUpdate = nil
        } catch {
            updateError = error.localizedDescription
        }
    }

    func checkInstallation() async {
        status = .checking
        let result = await Task.detached { Self.detectRelay() }.value

        switch result {
        case let .success(installation):
            status = .installed(path: installation.path, version: installation.version)
        case .failure:
            status = .missing
        }
    }

    func install() async {
        status = .installing

        do {
            try await Self.downloadAndInstall()
            let result = await Task.detached { Self.detectRelay() }.value
            switch result {
            case let .success(installation):
                status = .installed(path: installation.path, version: installation.version)
            case let .failure(error):
                status = .failure(error.localizedDescription)
            }
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    /// Runs `zrok2 admin …` against the configured server using the admin token.
    func runAdmin(_ arguments: [String], domain: String, adminToken: String) async throws -> String {
        let path = try await installedPath()
        guard let apiURL = Self.apiURL(forDomain: domain) else {
            throw SetupError.commandFailed("Set the relay domain first.")
        }

        let environment = [
            "ZROK2_API_ENDPOINT": apiURL.absoluteString,
            "ZROK2_ADMIN_TOKEN": adminToken
        ]
        let output = try await Task.detached {
            try Self.run(path, arguments: ["admin"] + arguments, environment: environment)
        }.value
        guard output.exitCode == 0 else { throw SetupError.commandFailed(Self.cleanError(output.text)) }
        return output.text
    }

    // MARK: - Environment (this Mac)

    struct Environment: Equatable, Sendable {
        let apiEndpoint: String
        let identity: String
    }

    /// The Mac's relay environment, written by `zrok2 enable` to ~/.zrok2/environment.json.
    nonisolated static func currentEnvironment() -> Environment? {
        let url = URL.homeDirectory.appending(path: ".zrok2/environment.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let endpoint = json["api_endpoint"] as? String,
              let identity = json["ziti_identity"] as? String
        else { return nil }
        return Environment(apiEndpoint: endpoint, identity: identity)
    }

    /// Whether this Mac is enabled against the relay configured for `domain`.
    nonisolated static func isConnected(domain: String) -> Bool {
        guard let environment = currentEnvironment(), let apiURL = apiURL(forDomain: domain) else { return false }
        return environment.apiEndpoint == apiURL.absoluteString
    }

    func connect(domain: String, accountToken: String) async throws {
        guard let apiURL = Self.apiURL(forDomain: domain) else {
            throw SetupError.commandFailed("Set the relay domain first.")
        }
        // An environment for another server (or a stale one) must go first.
        if Self.currentEnvironment() != nil {
            try await disconnect()
        }
        let description = Host.current().localizedName ?? "Mac"
        _ = try await runRelay(
            ["enable", accountToken, "-d", description, "--headless"],
            environment: ["ZROK2_API_ENDPOINT": apiURL.absoluteString]
        )
    }

    func disconnect() async throws {
        _ = try await runRelay(["disable"])
    }

    // MARK: - Names and shares

    /// Reserves `<name>.<domain>` for this account. Reusing a name this account already
    /// owns (e.g. from the other Mac) is fine; a name owned by someone else fails.
    func reserveName(_ name: String) async throws {
        do {
            _ = try await runRelay(["create", "name", name])
        } catch {
            // The server answers 409 both for "yours already" and "someone else's".
            guard error.localizedDescription.contains("409") else { throw error }
            if try await ownedNames().contains(name) { return }
            if error.localizedDescription.contains("not a valid share name") {
                throw SetupError.commandFailed("“\(name)” is not allowed. Try another subdomain.")
            }
            throw SetupError.commandFailed("“\(name)” is already taken. Try another subdomain.")
        }
    }

    func ownedNames() async throws -> [String] {
        struct Name: Decodable { let name: String }
        let output = try await runRelay(["list", "names", "--json"])
        return (try? JSONDecoder().decode([Name].self, from: Data(output.utf8)))?.map(\.name) ?? []
    }

    func releaseName(_ name: String) async throws {
        _ = try await runRelay(["delete", "name", name])
    }

    /// Deletes shares this Mac left behind for `name` (e.g. after a crash), which would
    /// otherwise keep the name "in use by another share".
    func deleteStaleShares(name: String, domain: String) async throws {
        guard let environment = Self.currentEnvironment() else { return }
        let output = try await runRelay(["list", "shares", "--json", "--env-zid", environment.identity])
        struct Listing: Decodable {
            struct Share: Decodable {
                let shareToken: String
                let frontendEndpoints: [String]?
            }
            let shares: [Share]
        }
        guard let data = output.data(using: .utf8),
              let listing = try? JSONDecoder().decode(Listing.self, from: data) else { return }

        let endpoint = "\(name).\(Self.normalizedDomain(domain))"
        for share in listing.shares where share.frontendEndpoints?.contains(endpoint) == true {
            _ = try await runRelay(["delete", "share", share.shareToken])
        }
    }

    /// Runs a relay command as this Mac's environment.
    @discardableResult
    func runRelay(_ arguments: [String], environment: [String: String] = [:]) async throws -> String {
        let path = try await installedPath()
        let output = try await Task.detached {
            try Self.run(path, arguments: arguments, environment: environment)
        }.value
        guard output.exitCode == 0 else { throw SetupError.commandFailed(Self.cleanError(output.text)) }
        return output.text
    }

    private func installedPath() async throws -> String {
        if case let .installed(path, _) = status { return path }
        await checkInstallation()
        guard case let .installed(path, _) = status else { throw SetupError.notInstalled }
        return path
    }

    /// Path of the relay client for callers that launch it themselves.
    nonisolated static var executablePath: String? {
        relayCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Turns "[ERROR]: unable to …" or JSON log lines into a readable message.
    nonisolated static func cleanError(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        if let error = lines.last(where: { $0.hasPrefix("[ERROR]") }) {
            return error.replacingOccurrences(of: "[ERROR]: ", with: "")
        }
        return text
    }

    private struct Installation: Sendable {
        let path: String
        let version: String
    }

    private enum SetupError: LocalizedError, Sendable {
        case notInstalled
        case downloadFailed(Int)
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                "The relay client is not installed."
            case let .downloadFailed(statusCode):
                "The relay client download failed (HTTP \(statusCode))."
            case let .commandFailed(output):
                output.isEmpty ? "The installation command failed." : output
            }
        }
    }

    /// App-managed install location: ~/Library/Application Support/Tunnelz/bin/zrok2
    nonisolated static var managedBinaryURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Tunnelz/bin", directoryHint: .isDirectory)
            .appending(path: "zrok2")
    }

    nonisolated private static var relayCandidates: [String] {
        [
            managedBinaryURL.path(percentEncoded: false),
            "/opt/homebrew/bin/zrok2",
            "/usr/local/bin/zrok2"
        ]
    }

    private struct Release: Sendable {
        let version: SemanticVersion
        let archiveURL: URL
        let sha256: String
    }

    /// Newest stable release in the supported major version, with the archive's SHA-256 published by GitHub.
    nonisolated private static func latestRelease() async throws -> Release {
        struct APIRelease: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
                let digest: String?
            }
            let tag_name: String
            let draft: Bool
            let prerelease: Bool
            let assets: [Asset]
        }

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/openziti/zrok/releases?per_page=50")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw SetupError.downloadFailed(http.statusCode)
        }

        #if arch(arm64)
        let archiveSuffix = "_darwin_arm64.tar.gz"
        #else
        let archiveSuffix = "_darwin_amd64.tar.gz"
        #endif
        let releases = try JSONDecoder().decode([APIRelease].self, from: data).compactMap { release -> Release? in
            guard !release.draft, !release.prerelease,
                  let version = SemanticVersion(release.tag_name),
                  version.major == supportedMajorVersion,
                  let asset = release.assets.first(where: { $0.name.hasPrefix("zrok_") && $0.name.hasSuffix(archiveSuffix) }),
                  let digest = asset.digest, digest.hasPrefix("sha256:")
            else { return nil }
            return Release(version: version, archiveURL: asset.browser_download_url, sha256: String(digest.dropFirst(7)))
        }
        guard let latest = releases.max(by: { $0.version < $1.version }) else {
            throw SetupError.commandFailed("No compatible relay client release was found.")
        }
        return latest
    }

    nonisolated private static func downloadAndInstall() async throws {
        let release = try await latestRelease()
        let (archiveURL, response) = try await URLSession.shared.download(from: release.archiveURL)
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw SetupError.downloadFailed(http.statusCode)
        }

        let archive = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        let digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        guard digest == release.sha256.lowercased() else {
            throw SetupError.commandFailed("The downloaded relay client failed verification and was not installed.")
        }

        try await Task.detached {
            let fileManager = FileManager.default
            let extractDir = fileManager.temporaryDirectory
                .appending(path: "relay-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: extractDir) }

            let untar = try run(
                "/usr/bin/tar",
                arguments: ["-xzf", archiveURL.path(percentEncoded: false), "-C", extractDir.path(percentEncoded: false)]
            )
            guard untar.exitCode == 0 else { throw SetupError.commandFailed(untar.text) }

            let extracted = extractDir.appending(path: "zrok2")
            guard fileManager.fileExists(atPath: extracted.path(percentEncoded: false)) else {
                throw SetupError.commandFailed("The downloaded archive does not contain the relay client.")
            }

            let destination = managedBinaryURL
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: extracted, to: destination)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path(percentEncoded: false))
        }.value
    }

    nonisolated private static func detectRelay() -> Result<Installation, SetupError> {
        guard let path = executablePath else {
            return .failure(.notInstalled)
        }

        do {
            let output = try run(path, arguments: ["version"])
            guard output.exitCode == 0 else {
                return .failure(.commandFailed(output.text))
            }
            // `zrok2 version` prints an ASCII banner followed by "v2.0.4 [commit]".
            let version = output.text
                .split(whereSeparator: \.isNewline)
                .last
                .map { String($0).trimmingCharacters(in: .whitespaces) } ?? output.text
            return .success(Installation(path: path, version: version))
        } catch {
            return .failure(.commandFailed(error.localizedDescription))
        }
    }

    nonisolated private static func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) throws -> (exitCode: Int32, text: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, text)
    }
}
