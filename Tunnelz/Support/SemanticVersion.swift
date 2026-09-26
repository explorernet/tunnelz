import Foundation

/// A `major.minor.patch` version found anywhere in a string ("v2.0.4 [abc]", "cloudflared version 2025.9.1 (built …)").
nonisolated struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let components: [Int]

    init?(_ text: String) {
        guard let match = text.firstMatch(of: /(\d+)\.(\d+)(?:\.(\d+))?/),
              let major = Int(match.1), let minor = Int(match.2) else { return nil }
        components = [major, minor, match.3.flatMap { Int($0) } ?? 0]
    }

    var major: Int { components[0] }

    var description: String {
        components.map(String.init).joined(separator: ".")
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}
