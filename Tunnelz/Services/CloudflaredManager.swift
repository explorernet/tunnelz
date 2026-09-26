import Foundation
import Observation

@MainActor
@Observable
final class CloudflaredManager {
    enum Status: Equatable {
        case checking
        case missing
        case installing
        case installed(path: String, version: String)
        case failure(String)
    }

    private(set) var status: Status = .checking
    private(set) var availableUpdate: SemanticVersion?
    private(set) var isUpdating = false
    private(set) var didCheckForUpdates = false
    private(set) var updateError: String?

    /// Asks Homebrew whether a newer cloudflared exists. Copies not installed by Homebrew are left alone.
    func checkForUpdates() async {
        let result = await Task.detached { () -> (installed: SemanticVersion, stable: SemanticVersion)? in
            guard let brew = Self.firstExecutable(in: Self.homebrewCandidates),
                  let output = try? Self.run(brew, arguments: ["info", "--json=v2", "cloudflared"]),
                  output.exitCode == 0 else { return nil }
            struct Info: Decodable {
                struct Formula: Decodable {
                    struct Versions: Decodable { let stable: String }
                    struct Installed: Decodable { let version: String }
                    let versions: Versions
                    let installed: [Installed]
                }
                let formulae: [Formula]
            }
            guard let formula = try? JSONDecoder().decode(Info.self, from: Data(output.text.utf8)).formulae.first,
                  let installed = formula.installed.last.flatMap({ SemanticVersion($0.version) }),
                  let stable = SemanticVersion(formula.versions.stable) else { return nil }
            return (installed, stable)
        }.value

        guard let result else {
            didCheckForUpdates = false
            return
        }
        availableUpdate = result.stable > result.installed ? result.stable : nil
        didCheckForUpdates = true
    }

    func update() async {
        isUpdating = true
        updateError = nil
        defer { isUpdating = false }

        let result = await Task.detached { () -> Result<Installation, SetupError> in
            guard let brew = Self.firstExecutable(in: Self.homebrewCandidates) else {
                return .failure(.homebrewMissing)
            }
            do {
                let output = try Self.run(brew, arguments: ["upgrade", "cloudflared"])
                guard output.exitCode == 0 else { return .failure(.commandFailed(output.text)) }
                return Self.detectCloudflared()
            } catch {
                return .failure(.commandFailed(error.localizedDescription))
            }
        }.value

        switch result {
        case let .success(installation):
            status = .installed(path: installation.path, version: installation.version)
            availableUpdate = nil
        case let .failure(error):
            updateError = error.localizedDescription
        }
    }

    func checkInstallation() async {
        status = .checking
        let result = await Task.detached { Self.detectCloudflared() }.value

        switch result {
        case let .success(installation):
            status = .installed(path: installation.path, version: installation.version)
        case .failure:
            status = .missing
        }
    }

    func install() async {
        status = .installing

        let result = await Task.detached { () -> Result<Installation, SetupError> in
            guard let brew = Self.firstExecutable(in: Self.homebrewCandidates) else {
                return .failure(.homebrewMissing)
            }

            do {
                let output = try Self.run(brew, arguments: ["install", "cloudflared"])
                guard output.exitCode == 0 else {
                    return .failure(.commandFailed(output.text))
                }
                return Self.detectCloudflared()
            } catch {
                return .failure(.commandFailed(error.localizedDescription))
            }
        }.value

        switch result {
        case let .success(installation):
            status = .installed(path: installation.path, version: installation.version)
        case let .failure(error):
            status = .failure(error.localizedDescription)
        }
    }

    private struct Installation: Sendable {
        let path: String
        let version: String
    }

    private enum SetupError: LocalizedError, Sendable {
        case notInstalled
        case homebrewMissing
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                "cloudflared is not installed."
            case .homebrewMissing:
                "Homebrew was not found in /opt/homebrew or /usr/local."
            case let .commandFailed(output):
                output.isEmpty ? "The installation command failed." : output
            }
        }
    }

    private static let cloudflaredCandidates = [
        "/opt/homebrew/bin/cloudflared",
        "/usr/local/bin/cloudflared"
    ]

    private static let homebrewCandidates = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew"
    ]

    nonisolated private static func detectCloudflared() -> Result<Installation, SetupError> {
        guard let path = firstExecutable(in: cloudflaredCandidates) else {
            return .failure(.notInstalled)
        }

        do {
            let output = try run(path, arguments: ["--version"])
            guard output.exitCode == 0 else {
                return .failure(.commandFailed(output.text))
            }
            return .success(Installation(path: path, version: output.text))
        } catch {
            return .failure(.commandFailed(error.localizedDescription))
        }
    }

    nonisolated private static func firstExecutable(in candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated private static func run(
        _ executable: String,
        arguments: [String]
    ) throws -> (exitCode: Int32, text: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
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
